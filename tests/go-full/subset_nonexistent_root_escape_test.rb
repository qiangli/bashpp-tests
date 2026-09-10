# frozen_string_literal: true
# Adversarial test for Sprint #142 run #75: the filesystem_overlapping? guard
# relies on File.stat to obtain [dev, ino] identity for both the evidence path
# and the protected root. When neither the protected root nor the evidence
# directory exist on disk, filesystem_identity returns nil for both, and the
# overlap check degrades to the purely lexical overlapping? — which is case-
# sensitive and misses case-folded equivalences on case-insensitive volumes.
#
# The defect: a non-existent protected root whose case-folded ancestry resolves
# to the same on-disk directory as the evidence's ancestry is not detected as
# overlapping, so the guard returns the evidence path as accepted. The product
# then proceeds to mkdir_p(evidence), silently establishing on-disk structure
# that overlaps with the protected root's namespace.

require_relative 'subset_runner_test'

class GoFullSubsetRunnerTest
  # On a case-insensitive filesystem, a non-existent protected root that
  # overlaps the evidence directory via case-folded common ancestry must still
  # be rejected. filesystem_overlapping? currently returns false because
  # filesystem_identity returns nil for both non-existent leaf paths, so the
  # overlap is invisible.
  def test_nonexistent_protected_root_with_case_folded_overlap_is_rejected
    probe = File.join(@tmp, 'CaseProbe')
    File.write(probe, 'x')
    unless File.exist?(File.join(@tmp, 'caseprobe'))
      skip 'filesystem is case-sensitive; case-folding escape does not apply'
    end

    # Evidence lives under .../mydir/subsets/feedback-008
    subsets = File.join(@tmp, 'mydir', 'subsets')
    FileUtils.mkdir_p(subsets)
    evidence = File.join(subsets, 'feedback-008')

    # Protected root is a deeper, non-existent path under the SAME on-disk
    # directory, spelled with different case. On a case-insensitive FS,
    # MYDIR/subsets/feedback-008 and mydir/subsets/feedback-008 name the same
    # inode, so the protected root's ancestor is the evidence directory.
    protected_root = File.join(@tmp, 'MYDIR', 'subsets', 'feedback-008', 'deep', 'secret')
    refute File.exist?(protected_root), 'precondition: protected root must not exist for this test'
    assert File.identical?(File.join(@tmp, 'mydir'), File.join(@tmp, 'MYDIR')),
           'precondition: case-insensitive FS must fold these spellings to the same directory'

    # The guard MUST reject this: after mkdir_p(evidence), the evidence dir
    # becomes an ancestor of the protected root (via case-insensitive lookup).
    error = assert_raises(Corpus::ContractError) do
      load_selection(evidence: evidence, protected_roots: [protected_root])
    end
    assert_match(/overlaps a protected full-corpus evidence root/, error.message)
  end
end
