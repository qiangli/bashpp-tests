# frozen_string_literal: true
# Adversarial test for Sprint #142 Story #24 run #69: the "repair subset
# symlink evidence escape" fix resolves the evidence path through symlinks and
# then compares it against the protected roots, but the comparison
# (GoFullSubset.overlapping? -> String#start_with?) is case-sensitive while the
# claimed protection is a filesystem-identity guarantee. On a case-insensitive
# filesystem a subset run can point its `subsets` directory at a
# differently-cased spelling of a protected full-corpus evidence root; the
# canonical form retains that spelling (File.symlink? follows the link
# case-insensitively to the real, non-symlink directory), so the overlap is
# missed and the caller's mkdir_p(evidence) writes straight into the protected
# corpus directory.

require_relative 'subset_runner_test'

class GoFullSubsetRunnerTest
  def test_case_folded_subsets_symlink_escapes_protected_full_corpus_root
    probe = File.join(@tmp, 'CaseProbe')
    File.write(probe, 'x')
    unless File.exist?(File.join(@tmp, 'caseprobe'))
      skip 'filesystem is case-sensitive; the case-folding evidence-escape vector does not apply here'
    end

    protected_evidence = File.join(@tmp, 'evidence', 'go-full', 'product-all-008')
    FileUtils.mkdir_p(protected_evidence)
    work = File.join(@tmp, 'work')
    FileUtils.mkdir_p(work)
    # Same on-disk directory as the protected root, spelled with a different case.
    aliased = File.join(@tmp, 'evidence', 'go-full', 'Product-All-008')
    File.symlink(aliased, File.join(work, 'subsets'))
    escaped = File.join(work, 'subsets', 'feedback-008')

    error = assert_raises(Corpus::ContractError) do
      load_selection(evidence: escaped, protected_roots: [protected_evidence])
    end
    assert_match(/overlaps a protected full-corpus evidence root/, error.message)

    # The consequence the guard exists to prevent: the accepted evidence path,
    # written the way the product driver writes it, lands inside the protected
    # full-corpus evidence directory.
    FileUtils.mkdir_p(escaped)
    refute File.exist?(File.join(protected_evidence, 'feedback-008')),
           'a case-folded subsets symlink resolved into a protected full-corpus evidence root'
  end
end
