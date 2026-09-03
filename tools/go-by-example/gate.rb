#!/usr/bin/env ruby
require "base64"; require "digest"; require "fileutils"; require "json"; require "open3"; require "openssl"; require "rbconfig"; require "socket"; require "tmpdir"
require_relative "normalizer"
Thread.report_on_exception = false
ROOT=File.expand_path("../..",__dir__); INV=ENV.fetch("GBE_INVENTORY",ROOT+"/docs/go-by-example/inventory.tsv"); SCHEMA=ENV.fetch("GBE_SCHEMA",ROOT+"/docs/go-by-example/behavior-schema.tsv")
CLS=ROOT+"/docs/go-by-example/classification.tsv"; EPIN=ROOT+"/docs/go-by-example/executor.tsv"; RESULTS=ENV.fetch("GBE_RESULTS",ROOT+"/.cache/go-by-example/results.jsonl"); LIMIT=Float(ENV.fetch("GBE_ROW_TIMEOUT","90")); COMPILE_LIMIT=Float(ENV.fetch("GBE_COMPILE_TIMEOUT","25")); RUN_LIMIT=Float(ENV.fetch("GBE_RUN_TIMEOUT","20")); CLEANUP_LIMIT=Float(ENV.fetch("GBE_CLEANUP_TIMEOUT","2")); BASHY=File.expand_path(ENV.fetch("BASHY_BIN",ROOT+"/.cache/go-by-example/executor/bash"))
SENTINEL_FD=9
def fatal(s); abort("FATAL: #{s}"); end
def sha(p); Digest::SHA256.file(p).hexdigest; end
def toks(s); s=="none" ? [] : s.split(","); end
def left(d); d-Process.clock_gettime(Process::CLOCK_MONOTONIC); end
def native?(p);m=File.binread(p,4);m.start_with?("\xCF\xFA\xED\xFE".b,"\xFE\xED\xFA\xCF".b,"\x7FELF".b,"MZ".b);end
system(ROOT+"/tools/go-by-example/validate.sh") or fatal("corpus integrity gate failed") unless ENV["GBE_SKIP_INTEGRITY"]=="1"
os=RbConfig::CONFIG["host_os"].sub(/darwin.*/,"darwin").sub(/linux.*/,"linux"); arch=RbConfig::CONFIG["host_cpu"].sub("aarch64","arm64").sub("x86_64","amd64")
pin=File.readlines(ROOT+"/docs/go-by-example/toolchain.tsv",chomp:true).reject{|x|x.empty?||x.start_with?("#")}.map{|x|x.split("\t",-1)}.find{|r|r[0]==os&&r[1]==arch};fatal("no authenticated Go 1.27.0 toolchain for #{os}/#{arch}") unless pin
goroot,st=Open3.capture2({"GOTOOLCHAIN"=>"go1.27.0"},"go","env","GOROOT");fatal("cannot resolve pinned Go toolchain") unless st.success?;go=goroot.strip+"/bin/go";ver,st=Open3.capture2(go,"version")
fatal("Go identity mismatch") unless st.success?&&ver.strip==pin[3];fatal("Go binary checksum mismatch") unless sha(go)==pin[4];fatal("Go release source mismatch") unless File.readlines(goroot.strip+"/VERSION").first.strip=="go1.27.0";fatal("Go tool is not native") unless native?(go)
# The executable may be selected by path, but its authority is a digest in the
# reviewed repository. There is no caller-provided matching hash/version.
ep=File.readlines(EPIN,chomp:true).reject{|x|x.empty?||x.start_with?("#")}.map{|x|x.split("\t",-1)}.find{|r|r[0]==os&&r[1]==arch};fatal("no repository-reviewed Bash++ executor pin for #{os}/#{arch}") unless ep
fatal("executor pin is not independently derivable") unless ep.size==8&&ep[3]=~/\Ahttps:\/\//&&ep[4]=~/\A[0-9a-f]{40}\z/&&ep[5]=~/\A[0-9a-f]{40}\z/&&ep[7].include?("-trimpath")&&ep[7].include?("-buildid=")
fatal("executor pin was not built by the pinned Go toolchain: #{ep[6].inspect} != #{pin[3].inspect}") unless ep[6]==pin[3]
fatal("invalid repository-reviewed Bash++ executor checksum") unless ep[2]&.match?(/\A[0-9a-f]{64}\z/)&&ep[2]!~/\A0+\z/;fatal("Bash++ executable missing: #{BASHY}") unless File.file?(BASHY)&&File.executable?(BASHY)
real=File.realpath(BASHY);bsha=sha(real);fatal("Bash++ executor differs from repository-reviewed artifact") unless bsha==ep[2];bver,st=Open3.capture2e(BASHY,"--version");fatal("Bash++ identity command failed") unless st.success?&&!bver.empty?
ADAPTERS=%w[none argv_fixture fixed_env hermetic_cwd tmpdir input_file_fixture stdin_fixture local_http_origin loopback_server signal_injector exit_status_capture seeded_random fake_clock bounded_wait go_test_runner]
NORMS=GoByExampleNormalizer::NAMES
schema=File.readlines(SCHEMA,chomp:true).map{|x|x.split("\t",-1)};fatal("adapter registry differs from schema") unless schema.map{|r|r[1] if r[0]=="adapter"}.compact.sort==ADAPTERS.sort;fatal("normalizer registry differs from schema") unless schema.map{|r|r[1] if r[0]=="normalization"}.compact.sort==NORMS.sort
rows=File.readlines(INV,chomp:true).reject{|x|x.empty?||x.start_with?("#")}.map{|x|x.split("\t",-1)}.select{|r|%w[program test_program].include?(r[1])};fatal("expected exactly 85 program rows, got #{rows.size}") unless rows.size==85
rows.each{|r|p=ROOT+"/"+r[0];fatal("source changed during gate: #{r[0]}") unless File.file?(p)&&File.size(p).to_s==r[6]&&sha(p)==r[7]}

def sig(s,p)
 Process.kill(s,-p)
rescue Errno::ESRCH, Errno::EPERM
 nil
end
def alive?(p)
 Process.kill(0,-p); true
rescue Errno::ESRCH
 false
rescue Errno::EPERM
 true
end
def sentinel_held?(io,budget)
 deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+budget
 loop do
  remaining=deadline-Process.clock_gettime(Process::CLOCK_MONOTONIC)
  return true if remaining<=0
  return true unless IO.select([io],nil,nil,remaining)
  begin
   io.read_nonblock(4096)
  rescue EOFError
   return false
  rescue IO::WaitReadable
   next
  rescue IOError, Errno::EBADF
   return false
  end
 end
end
def drive(path,d)
 s=nil;until s;raise "server adapter deadline" unless left(d)>0;s=TCPSocket.new("127.0.0.1",8090) rescue nil;sleep([0.02,left(d)].min) unless s;end
 if path.include?("tcp-server");s.write("hello adapter\n");raise "bad TCP response" unless s.gets=="ACK: HELLO ADAPTER\n";else;s.write("GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");raise "bad HTTP response" unless path.include?("context/")||s.read.include?("hello");end
ensure s&.close end
class Origin
 attr_reader :url
 def initialize(d,dir);@d=d;key=OpenSSL::PKey::RSA.new(2048);cert=OpenSSL::X509::Certificate.new;cert.version=2;cert.serial=1;cert.subject=cert.issuer=OpenSSL::X509::Name.parse("/CN=gobyexample.com");cert.public_key=key.public_key;cert.not_before=Time.at(0);cert.not_after=Time.utc(2100);ef=OpenSSL::X509::ExtensionFactory.new;ef.subject_certificate=ef.issuer_certificate=cert;cert.add_extension(ef.create_extension("basicConstraints","CA:TRUE",true));cert.add_extension(ef.create_extension("subjectAltName","DNS:gobyexample.com"));cert.sign(key,OpenSSL::Digest::SHA256.new);@ca=dir+"/hermetic-ca.pem";File.write(@ca,cert.to_pem);@ctx=OpenSSL::SSL::SSLContext.new;@ctx.cert=cert;@ctx.key=key;@tcp=TCPServer.new("127.0.0.1",0);@url="http://127.0.0.1:#{@tcp.addr[1]}";@error=nil;@thread=Thread.new do;begin;c=@tcp.accept;line=c.gets;raise "expected CONNECT gobyexample.com:443" unless line&.start_with?("CONNECT gobyexample.com:443 ");loop{break if c.gets=="\r\n"};c.write("HTTP/1.1 200 Connection Established\r\n\r\n");ssl=OpenSSL::SSL::SSLSocket.new(c,@ctx);ssl.sync_close=true;ssl.accept;ssl.readpartial(4096);body="<!doctype html>\n<html>\n<head><title>Go by Example</title></head>\n<body>\n<h1>Go by Example</h1>\n";ssl.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}");ssl.close;rescue IOError,Errno::EBADF,EOFError=>e;@error=e;rescue=>e;@error=e;end;end;end
 def apply(e); e.merge("HTTPS_PROXY"=>@url,"https_proxy"=>@url,"SSL_CERT_FILE"=>@ca); end
 def close;@tcp.close rescue nil;budget=[left(@d),CLEANUP_LIMIT].min;ok=budget>0&&@thread.join(budget);@thread.kill unless ok;@thread.join(CLEANUP_LIMIT);raise @error if @error&&!@error.is_a?(IOError)&&!@error.is_a?(Errno::EBADF)&&!@error.is_a?(EOFError);ok end
end
def run(cmd,cwd,env,input,outer,child_limit,path,ad)
 d=[outer,Process.clock_gettime(Process::CLOCK_MONOTONIC)+child_limit].min;r={"exit"=>nil,"state"=>"unspawned","spawned"=>false,"stdout"=>"","stderr"=>"","command"=>cmd};origin=nil;threads=[];readers=[];p=nil;t=nil;sentinel_r=nil;sentinel_w=nil
 begin
  raise "child deadline expired before spawn" unless left(d)>0;origin=Origin.new(d,cwd) if ad.include?("local_http_origin");env=origin.apply(env) if origin
  sentinel_r,sentinel_w=IO.pipe;i,o,e,t=Open3.popen3(env,*cmd,chdir:cwd,pgroup:true,unsetenv_others:true,SENTINEL_FD=>sentinel_w);p=t.pid;sentinel_w.close;sentinel_w=nil;r["spawned"]=true;r["state"]="spawned";readers=[Thread.new{o.read},Thread.new{e.read}];i.write(input);i.close;threads<<Thread.new{drive(path,d);sig("TERM",p)} if ad.include?("loopback_server");threads<<Thread.new{sleep([0.05,[left(d),0].max].min);sig("INT",p) if left(d)>0} if ad.include?("signal_injector")
  if left(d)>0&&t.join(left(d));s=t.value;r["exit"]=s.exitstatus||128+s.termsig;r["state"]="complete" else r["state"]="timeout" end
 rescue SystemCallError=>e;r["detail"]="#{e.class}: #{e.message}"
 rescue=>e;r["state"]="adapter_error";r["detail"]="#{e.class}: #{e.message}"
 ensure
  if p&&alive?(p);sig("TERM",p);t&.join(CLEANUP_LIMIT);sig("KILL",p) if alive?(p);t&.join(CLEANUP_LIMIT);end
  (threads+readers).each{|th|unless th.join(CLEANUP_LIMIT);r["state"]="cleanup_error";r["detail"]=[r["detail"],"thread did not join within cleanup bound"].compact.join("; ");th.kill;th.join(CLEANUP_LIMIT);end;begin;th.value;rescue=>e;r["state"]="adapter_error";r["detail"]=[r["detail"],e.message].compact.join("; ");end}
  r["stdout"]=readers[0]&.value.to_s rescue r["stdout"];r["stderr"]=readers[1]&.value.to_s rescue r["stderr"]
  unless !origin||origin.close;r["state"]="cleanup_error";r["detail"]=[r["detail"],"origin thread did not join by row deadline"].compact.join("; ") end
  if p&&alive?(p);sig("KILL",p);sleep 0.02;end
  # A surviving descendant is observed, never asserted: the read end blocks
  # for as long as any descendant still holds the inherited write end. Only
  # consulted once the direct child has been reaped, so an unreaped child is
  # still diagnosed as timeout/cleanup_error rather than mislabelled a leak.
  if p&&sentinel_r&&(t.nil?||!t.alive?)&&sentinel_held?(sentinel_r,CLEANUP_LIMIT);r["state"]="leak";r["detail"]=[r["detail"],"descendant survived process-group termination still holding the inherited liveness descriptor"].compact.join("; ");end
  sentinel_r&.close;sentinel_w&.close
 end;r
end
def rec(path,mode,r,norm,binding,verdict,artifact=nil);h={"type"=>"attempt","path"=>path,"mode"=>mode,"spawned"=>r["spawned"],"state"=>r["state"],"exit"=>r["exit"],"raw_stdout_b64"=>Base64.strict_encode64(r["stdout"]),"raw_stderr_b64"=>Base64.strict_encode64(r["stderr"]),"normalized_stdout_b64"=>norm&&Base64.strict_encode64(norm[0]),"normalized_stderr_b64"=>norm&&Base64.strict_encode64(norm[1]),"verdict"=>verdict,"detail"=>r["detail"],"binding_sha256"=>binding,"artifact"=>artifact}.compact;h["evidence_sha256"]=Digest::SHA256.hexdigest(JSON.generate(h));h end
stat=File.stat(real);executor={"path"=>real,"sha256"=>bsha,"pin_sha256"=>sha(EPIN),"source_commit"=>ep[4],"source_tree"=>ep[5],"version_sha256"=>Digest::SHA256.hexdigest(bver),"device"=>stat.dev,"inode"=>stat.ino};corpus_root=Digest::SHA256.hexdigest(rows.map{|r|"#{r[0]}\0#{r[7]}\n"}.join);normalizer_path=ROOT+"/tools/go-by-example/normalizer.rb";normalizer_sha=sha(normalizer_path);manifest={"type"=>"manifest","schema"=>6,"story"=>"Sprint98/Story198/fa07603b71dc","corpus_sha256"=>sha(INV),"corpus_root_sha256"=>corpus_root,"behavior_schema_sha256"=>sha(SCHEMA),"classification_sha256"=>sha(CLS),"normalizer_version"=>GoByExampleNormalizer::VERSION,"normalizer_sha256"=>normalizer_sha,"toolchain_sha256"=>sha(ROOT+"/docs/go-by-example/toolchain.tsv"),"go_sha256"=>pin[4],"executor"=>executor,"denominator"=>{"rows"=>85,"modes_per_row"=>3,"attempts"=>255},"modes"=>%w[oracle interpreted compiled]};binding=Digest::SHA256.hexdigest(JSON.generate(manifest));records=[manifest];failures=[];incomplete=false
Dir.mktmpdir("gbe-gate-") do|base|;rows.each_with_index do|row,index|;d=Process.clock_gettime(Process::CLOCK_MONOTONIC)+LIMIT;path,kind,_,nv,av,req=row.values_at(0,1,2,3,4,5);source=ROOT+"/"+path;work=base+"/%03d"%index;tmp=work+"/tmp";FileUtils.mkdir_p(tmp);ad=toks(av);ns=toks(nv);File.binwrite(tmp+"/dat","hello\ngo\n") if ad.include?("input_file_fixture");toks(req).each{|a|FileUtils.cp(ROOT+"/"+a,work+"/"+File.basename(a))}
 env={"PATH"=>"/usr/bin:/bin","LANG"=>"C.UTF-8","LC_ALL"=>"C.UTF-8","HOME"=>work,"TMPDIR"=>tmp,"GOTOOLCHAIN"=>"local","TZ"=>"UTC","BAR"=>""};input=ad.include?("stdin_fixture") ? "hello\nworld\n":"";args=ad.include?("argv_fixture") ? %w[foo bar baz]:[];testdir=work;if kind=="test_program";FileUtils.cp(source,testdir+"/main_test.go");File.write(testdir+"/go.mod","module gbe.test\n\ngo 1.27\n");end
 artifact=work+"/bashpp-bin";build=run([BASHY,"--bashpp","--compile","-o",artifact,source],work,env,"",d,COMPILE_LIMIT,path,ad-%w[loopback_server signal_injector local_http_origin]);ainfo={"builder_sha256"=>bsha,"source_sha256"=>row[7],"compile_state"=>build["state"],"compile_spawned"=>build["spawned"],"compile_exit"=>build["exit"]};if build["state"]=="complete"&&build["exit"]==0&&File.file?(artifact)&&File.executable?(artifact)&&File.size(artifact)>0&&native?(artifact);ainfo.merge!({"sha256"=>sha(artifact),"bytes"=>File.size(artifact)});end
 cmds={"oracle"=>[go,kind=="test_program" ? "test":"run",kind=="test_program" ? ".":source,*args],"interpreted"=>[BASHY,"--bashpp",source,*args],"compiled"=>[artifact,*args]};got={};cmds.each{|mode,c|got[mode]=run(c,work,env,input,d,RUN_LIMIT,path,ad)};incomplete||=got.values.any?{|r|r["state"]!="complete"||!r["spawned"]};ref=got["oracle"];rn=begin[GoByExampleNormalizer.normalize(ref["stdout"],ns,:stdout),GoByExampleNormalizer.normalize(ref["stderr"],ns,:stderr)]rescue nil end
 got.each{|mode,r|norm=begin;[GoByExampleNormalizer.normalize(r["stdout"],ns,:stdout),GoByExampleNormalizer.normalize(r["stderr"],ns,:stderr)];rescue=>e;r["detail"]=[r["detail"],e.message].compact.join("; ");nil;end;v=r["state"]!="complete" ? "fail_incomplete":norm.nil?||rn.nil? ? "fail_normalization":mode=="oracle" ? "pass":r["exit"]==ref["exit"]&&norm==rn ? "pass":"fail_mismatch";failures<<"#{path}:#{mode}:#{v}" unless v=="pass";records<<rec(path,mode,r,norm,binding,v,mode=="compiled" ? ainfo:nil)};FileUtils.rm_rf(work)
end;end
failures<<"missing-attempt evidence: expected 255 attempt records, got #{records.count{|r|r['type']=='attempt'}}" unless records.count{|r|r["type"]=="attempt"}==255;failures<<"executor mutation during gate" unless File.realpath(BASHY)==real&&sha(real)==bsha&&File.stat(real).ino==executor["inode"]
records.each{|r|next unless r["type"]=="attempt";body=r.reject{|k,_|k=="evidence_sha256"};fatal("result tampering detected") unless r["binding_sha256"]==binding&&r["evidence_sha256"]==Digest::SHA256.hexdigest(JSON.generate(body))}
# Temp workspace cleanup and all joins precede publication. Unspawned commands
# remain attempt evidence, but are never included in the executed numerator.
attempts=records.count{|r|r["type"]=="attempt"};executed=records.count{|r|r["type"]=="attempt"&&r["spawned"]};failures=records.select{|r|r["type"]=="attempt"&&r["verdict"]!="pass"}.map{|r|"#{r['path']}:#{r['mode']}:#{r['verdict']}"};verdict=failures.empty?&&!incomplete&&attempts==255&&executed==255 ? "pass":"fail";summary={"type"=>"summary","verdict"=>verdict,"denominator"=>255,"attempt_records"=>attempts,"executed"=>executed,"missing_or_unspawned"=>255-executed,"failures"=>failures,"corpus_sha256"=>manifest["corpus_sha256"],"corpus_root_sha256"=>corpus_root,"behavior_schema_sha256"=>manifest["behavior_schema_sha256"],"classification_sha256"=>manifest["classification_sha256"],"normalizer_version"=>manifest["normalizer_version"],"normalizer_sha256"=>normalizer_sha,"toolchain_sha256"=>manifest["toolchain_sha256"],"go_sha256"=>manifest["go_sha256"],"executor_pin_sha256"=>executor["pin_sha256"],"executor_sha256"=>bsha};summary_hash=Digest::SHA256.hexdigest(JSON.generate(summary));root_digest=Digest::SHA256.hexdigest(([Digest::SHA256.hexdigest(JSON.generate(manifest))]+records.select{|r|r["type"]=="attempt"}.map{|r|r["evidence_sha256"]}+[summary_hash]).join("\n"));summary["root_digest"]=root_digest;records<<summary
FileUtils.mkdir_p(File.dirname(RESULTS));dest="#{RESULTS}.#{verdict}";payload=records.map{|r|JSON.generate(r)}.join("\n")+"\n";temp=dest+".tmp.#{$$}";File.open(temp,"wb",0600){|f|f.write(payload);f.flush;f.fsync};File.rename(temp,dest);fatal("verdict=fail denominator=255 executed=#{executed} missing=#{255-executed}; first: #{failures.first}; evidence: #{dest}") if verdict=="fail";puts "PASS: verdict=pass denominator=255 executed=255 evidence=#{dest} root_digest=#{root_digest}"
