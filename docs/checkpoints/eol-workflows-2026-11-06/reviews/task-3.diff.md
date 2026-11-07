Repository: /workspace/work/git-eol-workflows/replay
Base: 8d6309702ea47693f837d4be44fc090f43d49f78
Head: d9e2b57459c379200952f6808aea321773ab3179

## Commits

d9e2b57 Support configured EOL conversion in commit replay and rebase

## Stat

 spec/eol_replay_attributes_spec.cr      | 110 +++++++++++++++++++++++
 spec/eol_replay_partial_spec.cr         |  75 ++++++++++++++++
 spec/eol_replay_preparation_spec.cr     |  65 ++++++++++++++
 spec/eol_replay_recovery_spec.cr        | 154 ++++++++++++++++++++++++++++++++
 spec/eol_replay_spec.cr                 | 116 ++++++++++++++++++++++++
 src/git/workflow/rebase.cr              |  12 +--
 src/git/workflow/rebase/continuation.cr |  19 ++--
 src/git/workflow/rebase/initiate.cr     |   9 +-
 src/git/workflow/rebase/metadata.cr     |   6 ++
 src/git/workflow/rebase/preflight.cr    |   6 +-
 src/git/workflow/rebase/publication.cr  |  83 ++++++++++++++---
 src/git/workflow/rebase/replay.cr       |   6 +-
 src/git/workflow/sequencer.cr           |   9 +-
 src/git/workflow/sequencer/abort.cr     |  29 +++++-
 src/git/workflow/sequencer/initiate.cr  |   8 +-
 src/git/workflow/sequencer/metadata.cr  |   9 +-
 src/git/workflow/sequencer/recovery.cr  |  60 +++++++++++++
 src/git/workflow/sequencer/replay.cr    |  27 ++++--
 18 files changed, 748 insertions(+), 55 deletions(-)

## Diff

diff --git a/spec/eol_replay_attributes_spec.cr b/spec/eol_replay_attributes_spec.cr
new file mode 100644
index 0000000..d2a2921
--- /dev/null
+++ b/spec/eol_replay_attributes_spec.cr
@@ -0,0 +1,110 @@
+require "./eol_replay_spec"
+
+describe "native replay attribute sources" do
+  ["sha1", "sha256"].each do |format|
+    ["incoming", "deleted", "conflicted", "nested"].each do |source|
+      it "matches Git's #{format} #{source} planned attributes" do
+        GitOracle.with_repo(format: format) do |root|
+          attr = source == "nested" ? "nested/.gitattributes" : ".gitattributes"
+          file = source == "nested" ? "nested/file.txt" : "file.txt"
+          initial = source == "deleted" ? "*.txt text eol=crlf\n" : "*.txt text eol=lf\n"
+          EOLReplaySpec.write(root, attr, initial)
+          EOLReplaySpec.write(root, file, "base\n")
+          EOLReplaySpec.commit(root, "base")
+          GitOracle.run(root, "checkout", "-qb", "topic")
+          if source == "deleted"
+            GitOracle.run(root, "rm", attr)
+          else
+            EOLReplaySpec.write(root, attr, "*.txt text eol=crlf\n# topic\n")
+          end
+          EOLReplaySpec.write(root, file, "incoming\n")
+          EOLReplaySpec.commit(root, "incoming")
+          GitOracle.run(root, "checkout", "-q", "main")
+          if source == "conflicted"
+            EOLReplaySpec.write(root, attr, "*.txt text eol=lf\n# ours\n")
+            EOLReplaySpec.commit(root, "ours")
+          end
+          original = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
+          oracle = GitOracle.run(root, "cherry-pick", "topic", check: false)
+          oracle.success?.should eq(source != "conflicted")
+          expected = File.read(File.join(root, file))
+          if source == "conflicted"
+            GitOracle.run(root, "cherry-pick", "--abort")
+          else
+            GitOracle.run(root, "reset", "--hard", original)
+          end
+          repo = Git::Repository.new(root)
+          result = repo.cherry_pick("topic", committer: EOLReplaySpec.signature)
+          File.read(File.join(root, file)).should eq(expected)
+          EOLReplaySpec.blob(repo, file).should eq("incoming\n")
+          result.conflicts.should eq(source == "conflicted" ? [attr] : [] of String)
+          if source == "conflicted"
+            repo.cherry_pick.abort
+            File.read(File.join(root, file)).should eq("base\n")
+          end
+        end
+      end
+    end
+
+    it "preserves #{format} binary, symlink and unchanged canonical files" do
+      GitOracle.with_repo(format: format) do |root|
+        EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=lf\n*.bin text=auto\nraw.txt -text\n")
+        EOLReplaySpec.write(root, "unchanged.txt", "same\n")
+        EOLReplaySpec.commit(root, "base")
+        GitOracle.run(root, "checkout", "-qb", "topic")
+        EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=crlf\n*.bin text=auto\nraw.txt -text\n")
+        EOLReplaySpec.write(root, "binary.bin", "binary\0\r\n")
+        EOLReplaySpec.write(root, "raw.txt", "raw\r\n")
+        File.symlink("target\n", File.join(root, "link.txt"))
+        EOLReplaySpec.commit(root, "source")
+        GitOracle.run(root, "checkout", "-q", "main")
+        repo = Git::Repository.new(root)
+        repo.cherry_pick("topic", committer: EOLReplaySpec.signature)
+        File.read(File.join(root, "unchanged.txt")).should eq("same\n")
+        File.read(File.join(root, "binary.bin")).should eq("binary\0\r\n")
+        File.read(File.join(root, "raw.txt")).should eq("raw\r\n")
+        File.readlink(File.join(root, "link.txt")).should eq("target\n")
+      end
+    end
+
+    it "propagates explicit #{format} conversion config through replay and abort" do
+      GitOracle.with_repo(format: format) do |root|
+        EOLReplaySpec.write(root, "file", "base\n")
+        EOLReplaySpec.commit(root, "base")
+        GitOracle.run(root, "checkout", "-qb", "topic")
+        EOLReplaySpec.write(root, "file", "topic\n")
+        EOLReplaySpec.write(root, "added", "added\n")
+        EOLReplaySpec.commit(root, "source")
+        GitOracle.run(root, "checkout", "-q", "main")
+        EOLReplaySpec.write(root, "file", "ours\n")
+        EOLReplaySpec.commit(root, "ours")
+        repo = Git::Repository.new(root)
+        config = repo.config(command_values: [{"core.autocrlf", "true"}])
+        repo.cherry_pick("topic", committer: EOLReplaySpec.signature, config: config)
+        File.read(File.join(root, "file")).should contain("<<<<<<< HEAD\r\n")
+        File.read(File.join(root, "added")).should eq("added\r\n")
+        repo.cherry_pick.abort(config: config)
+        File.read(File.join(root, "file")).should eq("ours\r\n")
+      end
+    end
+
+    it "keeps unchanged #{format} canonical files intact during the rebase onto movement" do
+      GitOracle.with_repo(format: format) do |root|
+        EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=lf\n")
+        EOLReplaySpec.write(root, "unchanged.txt", "same\n")
+        EOLReplaySpec.commit(root, "base")
+        GitOracle.run(root, "checkout", "-qb", "topic")
+        EOLReplaySpec.write(root, "new.txt", "new\n")
+        EOLReplaySpec.commit(root, "new")
+        GitOracle.run(root, "checkout", "-q", "main")
+        EOLReplaySpec.write(root, ".gitattributes", "*.txt text eol=crlf\n")
+        EOLReplaySpec.commit(root, "attributes")
+        GitOracle.run(root, "checkout", "-q", "topic")
+        repo = Git::Repository.new(root)
+        repo.rebase("main", committer: EOLReplaySpec.signature).completed.should be_true
+        File.read(File.join(root, "unchanged.txt")).should eq("same\n")
+        File.read(File.join(root, "new.txt")).should eq("new\r\n")
+      end
+    end
+  end
+end
diff --git a/spec/eol_replay_partial_spec.cr b/spec/eol_replay_partial_spec.cr
new file mode 100644
index 0000000..04ca6a3
--- /dev/null
+++ b/spec/eol_replay_partial_spec.cr
@@ -0,0 +1,75 @@
+require "./eol_replay_spec"
+require "./support/merge_partial_recovery"
+
+describe "converted replay outputs before index publication" do
+  ["sha1", "sha256"].each do |format|
+    ["cherry-pick", "revert"].each do |operation|
+      it "owns only exact #{format} #{operation} relocation bytes after partial replay" do
+        GitOracle.with_repo(format: format) do |root|
+          EOLReplaySpec.write(root, ".gitattributes", "* text eol=crlf\n")
+          original = MergePartialRecoverySpec.fixture(root, operation, false)
+          GitOracle.run(root, "checkout-index", "--all", "--force")
+          check = -> do
+            if Dir.children(root).any?(&.starts_with?("node~"))
+              raise Git::Error.new("injected recovery failure")
+            end
+          end
+          MergePartialRecoverySpec.expect_partial(operation) do
+            MergePartialRecoverySpec.start(Git::Repository.new(root), operation, check)
+          end
+          relocated = Dir.children(root).find(&.starts_with?("node~")).not_nil!
+          output = File.read(File.join(root, relocated))
+          output.should contain("\r\n")
+          EOLReplaySpec.write(root, relocated, output.gsub("\r\n", "\n"))
+          expect_raises(Git::Error, /untracked|changed/) do
+            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
+          end
+          File.read(File.join(root, relocated)).should eq(output.gsub("\r\n", "\n"))
+          EOLReplaySpec.write(root, relocated, output)
+          MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
+          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original[0])
+          GitOracle.run(root, "ls-files", "-s").stdout.should eq(original[1])
+          File.read(File.join(root, "node-sibling")).should eq("preserve tracked sibling\r\n")
+          Dir.children(root).select(&.starts_with?("node~")).should be_empty
+        end
+      end
+
+      it "pins #{format} #{operation} original conversion identities across interrupted abort" do
+        GitOracle.with_repo(format: format) do |root|
+          EOLReplaySpec.write(root, ".gitattributes", "* text eol=crlf\n")
+          original = MergePartialRecoverySpec.fixture(root, operation, true)
+          GitOracle.run(root, "checkout-index", "--all", "--force")
+          MergePartialRecoverySpec.start(Git::Repository.new(root), operation)
+          injected = false
+          check = -> do
+            if !injected && File.file?(File.join(root, "node")) && File.exists?(File.join(root, "node~HEAD"))
+              injected = true
+              raise Git::Error.new("injected recovery failure")
+            end
+          end
+          MergePartialRecoverySpec.expect_partial(operation) do
+            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation, check)
+          end
+          injected.should be_true
+          File.read(File.join(root, "node")).should eq("changed\r\n")
+          EOLReplaySpec.write(root, "node", "changed\n")
+          EOLReplaySpec.write(root, ".git/info/attributes", "* text eol=lf\n")
+          expect_raises(Git::Error, /identities changed/) do
+            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
+          end
+          File.read(File.join(root, "node")).should eq("changed\n")
+          File.delete(File.join(root, ".git/info/attributes"))
+          expect_raises(Git::Error, /untracked|changed/) do
+            MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
+          end
+          EOLReplaySpec.write(root, "node", "changed\r\n")
+          MergePartialRecoverySpec.abort(Git::Repository.new(root), operation)
+          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original[0])
+          GitOracle.run(root, "ls-files", "-s").stdout.should eq(original[1])
+          File.read(File.join(root, "node")).should eq("changed\r\n")
+          File.exists?(File.join(root, ".git/CRYSTAL_SEQUENCER_RESTORE")).should be_false
+        end
+      end
+    end
+  end
+end
diff --git a/spec/eol_replay_preparation_spec.cr b/spec/eol_replay_preparation_spec.cr
new file mode 100644
index 0000000..082c690
--- /dev/null
+++ b/spec/eol_replay_preparation_spec.cr
@@ -0,0 +1,65 @@
+require "./eol_replay_spec"
+
+class Git::Repository
+  def eol_test_prepared_replay(hook : Proc(Array(Git::Index::Entry), Git::Merge::FilePlan, Int64)) : Git::Sequencer::Result
+    sequencer_start(Git::Sequencer::Kind::CherryPick, "topic", committer: EOLReplaySpec.signature,
+      author: nil, message: nil, mainline: nil, allow_empty: false,
+      max_object_bytes: 8_388_608, max_index_bytes: 8_388_608,
+      max_total_bytes: 67_108_864_i64, max_entries: 10_000,
+      check: nil, prepare_worktree: hook)
+  end
+end
+
+describe "replay supplemental output preparation" do
+  ["sha1", "sha256"].each do |format|
+    [-1_i64, 0_i64, 67_108_865_i64].each do |remaining|
+      it "checks #{format} hook budget #{remaining} before publication" do
+        GitOracle.with_repo(format: format) do |root|
+          original = EOLReplaySpec.fixture(root)
+          index = File.read(File.join(root, ".git/index"))
+          calls = 0
+          hook = ->(current : Array(Git::Index::Entry), plan : Git::Merge::FilePlan) do
+            calls += 1
+            current.any? { |entry| entry.path == "file.txt" }.should be_true
+            plan.writes.find { |write| write.path == "file.txt" }.not_nil!.data.should eq("topic\n")
+            File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD")).should be_false
+            remaining
+          end
+          expect_raises(Git::Error, /byte budget/) { Git::Repository.new(root).eol_test_prepared_replay(hook) }
+          calls.should eq(1)
+          File.read(File.join(root, ".git/index")).should eq(index)
+          File.read(File.join(root, "file.txt")).should eq("base\r\n")
+          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
+          File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD")).should be_false
+        end
+      end
+    end
+
+    it "cancels #{format} supplemental preparation before tracked publication" do
+      GitOracle.with_repo(format: format) do |root|
+        EOLReplaySpec.fixture(root)
+        hook = ->(_current : Array(Git::Index::Entry), _plan : Git::Merge::FilePlan) : Int64 do
+          raise Git::Error.new("cancel supplemental output")
+        end
+        expect_raises(Git::Error, "cancel supplemental output") { Git::Repository.new(root).eol_test_prepared_replay(hook) }
+        File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD")).should be_false
+        File.read(File.join(root, "file.txt")).should eq("base\r\n")
+      end
+    end
+
+    it "preserves an index mutation made by the #{format} preparation callback" do
+      GitOracle.with_repo(format: format) do |root|
+        EOLReplaySpec.fixture(root)
+        repo = Git::Repository.new(root)
+        hook = ->(_current : Array(Git::Index::Entry), _plan : Git::Merge::FilePlan) do
+          repo.stage_blob("callback", "preserve callback index mutation\n")
+          67_108_864_i64
+        end
+        expect_raises(Git::Error, /index changed/) { repo.eol_test_prepared_replay(hook) }
+        EOLReplaySpec.blob(repo, "callback").should eq("preserve callback index mutation\n")
+        File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD")).should be_false
+        File.read(File.join(root, "file.txt")).should eq("base\r\n")
+      end
+    end
+  end
+end
diff --git a/spec/eol_replay_recovery_spec.cr b/spec/eol_replay_recovery_spec.cr
new file mode 100644
index 0000000..1f252ce
--- /dev/null
+++ b/spec/eol_replay_recovery_spec.cr
@@ -0,0 +1,154 @@
+require "./eol_replay_spec"
+
+module EOLReplaySpec
+  def self.rebase_fixture(root : String, attributes : Bool = true) : String
+    ending = attributes ? "\r\n" : "\n"
+    write(root, ".gitattributes", "*.txt text eol=crlf\n") if attributes
+    write(root, "file.txt", "base#{ending}")
+    commit(root, "base")
+    GitOracle.run(root, "checkout", "-qb", "topic")
+    write(root, "file.txt", "topic#{ending}")
+    commit(root, "first")
+    write(root, "later.txt", "later#{ending}")
+    original = commit(root, "later")
+    GitOracle.run(root, "checkout", "-q", "main")
+    write(root, "file.txt", "upstream#{ending}")
+    write(root, "upstream.txt", "upstream#{ending}")
+    commit(root, "upstream")
+    GitOracle.run(root, "checkout", "-q", "topic")
+    original
+  end
+end
+
+describe "native replay raw recovery" do
+  ["sha1", "sha256"].each do |format|
+    ["continue", "skip"].each do |action|
+      it "forwards explicit #{format} conversion config to rebase #{action} and later items" do
+        GitOracle.with_repo(format: format) do |root|
+          EOLReplaySpec.rebase_fixture(root, false)
+          repo = Git::Repository.new(root)
+          config = repo.config(command_values: [{"core.autocrlf", "true"}])
+          repo.rebase("main", committer: EOLReplaySpec.signature, config: config)
+          File.read(File.join(root, "upstream.txt")).should eq("upstream\r\n")
+          if action == "continue"
+            EOLReplaySpec.write(root, "file.txt", "resolved\r\n")
+            repo.stage_file("file.txt", config: config)
+            repo.rebase.continue(committer: EOLReplaySpec.signature, config: config)
+          else
+            repo.rebase.skip(committer: EOLReplaySpec.signature, config: config)
+          end
+          File.read(File.join(root, "later.txt")).should eq("later\r\n")
+          EOLReplaySpec.blob(repo, "later.txt").should eq("later\n")
+        end
+      end
+    end
+
+    ["continue", "skip", "abort"].each do |action|
+      it "uses #{format} CRLF bytes through rebase onto and #{action}" do
+        GitOracle.with_repo(format: format) do |root|
+          original = EOLReplaySpec.rebase_fixture(root)
+          repo = Git::Repository.new(root)
+          repo.rebase("main", committer: EOLReplaySpec.signature).completed.should be_false
+          File.read(File.join(root, "upstream.txt")).should eq("upstream\r\n")
+          File.read(File.join(root, "file.txt")).should contain("<<<<<<< HEAD\r\n")
+          case action
+          when "continue"
+            EOLReplaySpec.write(root, "file.txt", "resolved\r\n")
+            repo.stage_file("file.txt")
+            repo.rebase.continue(committer: EOLReplaySpec.signature).completed.should be_true
+            EOLReplaySpec.blob(repo, "file.txt").should eq("resolved\n")
+            File.read(File.join(root, "later.txt")).should eq("later\r\n")
+          when "skip"
+            repo.rebase.skip(committer: EOLReplaySpec.signature).completed.should be_true
+            File.read(File.join(root, "file.txt")).should eq("upstream\r\n")
+            File.read(File.join(root, "later.txt")).should eq("later\r\n")
+          else
+            repo.rebase.abort(committer: EOLReplaySpec.signature)
+            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
+            File.read(File.join(root, "file.txt")).should eq("topic\r\n")
+            File.read(File.join(root, "later.txt")).should eq("later\r\n")
+          end
+          repo.rebase.state?.should be_nil
+          repo.working_changes(include_untracked: false).should be_empty
+        end
+      end
+    end
+
+    ["worktree", "reference"].each do |phase|
+      it "binds interrupted #{format} outer abort #{phase} to persisted raw identities" do
+        GitOracle.with_repo(format: format) do |root|
+          original = EOLReplaySpec.rebase_fixture(root)
+          repo = Git::Repository.new(root)
+          repo.rebase("main", committer: EOLReplaySpec.signature)
+          injected = false
+          check = -> do
+            if !injected && !File.exists?(File.join(root, ".git/REBASE_HEAD"))
+              restored = if phase == "reference"
+                           GitOracle.run(root, "rev-parse", "HEAD").stdout.strip == original
+                         else
+                           File.exists?(File.join(root, "later.txt"))
+                         end
+              if restored
+                injected = true
+                raise Git::Error.new("interrupt converted outer abort")
+              end
+            end
+          end
+          error = expect_raises(Git::Rebase::PartialPublication) do
+            repo.rebase.abort(committer: EOLReplaySpec.signature, check: check)
+          end
+          injected.should be_true
+          error.original_error.message.should eq("interrupt converted outer abort")
+          receipt_path = File.join(root, ".git/rebase-merge/worktree-restore")
+          receipt = File.read(receipt_path)
+          File.read(File.join(root, "later.txt")).should eq("later\r\n")
+          index = File.read(File.join(root, ".git/index"))
+          # Changing both an unindexed output and retry-time attributes must
+          # never turn a clean-equivalent replacement into owned output.
+          EOLReplaySpec.write(root, "later.txt", "later\n")
+          EOLReplaySpec.write(root, ".git/info/attributes", "*.txt text eol=lf\n")
+          expect_raises(Git::Error, /identities changed/) do
+            Git::Repository.new(root).rebase.abort(committer: EOLReplaySpec.signature)
+          end
+          File.read(File.join(root, "later.txt")).should eq("later\n")
+          File.read(receipt_path).should eq(receipt)
+          File.read(File.join(root, ".git/index")).should eq(index)
+          File.delete(File.join(root, ".git/info/attributes"))
+          expect_raises(Git::Error, /changed|untracked/) do
+            Git::Repository.new(root).rebase.abort(committer: EOLReplaySpec.signature)
+          end
+          EOLReplaySpec.write(root, "later.txt", "later\r\n")
+          # A missing versioned receipt fails closed as well.
+          File.delete(receipt_path)
+          expect_raises(Git::Error, /required.*missing/) do
+            Git::Repository.new(root).rebase.abort(committer: EOLReplaySpec.signature)
+          end
+          File.write(receipt_path, receipt)
+          Git::Repository.new(root).rebase.abort(committer: EOLReplaySpec.signature)
+          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
+          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
+          Dir.exists?(File.join(root, ".git/rebase-merge")).should be_false
+        end
+      end
+    end
+
+    it "refuses a clean-equivalent #{format} EOL race after replay metadata" do
+      GitOracle.with_repo(format: format) do |root|
+        EOLReplaySpec.fixture(root)
+        injected = false
+        check = -> do
+          if !injected && File.exists?(File.join(root, ".git/CHERRY_PICK_HEAD"))
+            injected = true
+            EOLReplaySpec.write(root, "file.txt", "base\n")
+          end
+        end
+        error = expect_raises(Git::Sequencer::PartialPublication) do
+          Git::Repository.new(root).cherry_pick("topic", committer: EOLReplaySpec.signature, check: check)
+        end
+        injected.should be_true
+        error.index_published.should be_false
+        File.read(File.join(root, "file.txt")).should eq("base\n")
+      end
+    end
+  end
+end
diff --git a/spec/eol_replay_spec.cr b/spec/eol_replay_spec.cr
new file mode 100644
index 0000000..b716df2
--- /dev/null
+++ b/spec/eol_replay_spec.cr
@@ -0,0 +1,116 @@
+require "spec"
+require "../src/git"
+require "./support/git_oracle"
+
+module EOLReplaySpec
+  def self.signature : Git::Signature
+    Git::Signature.new("Replay", "replay@example.invalid", 1_700_000_000_i64, 0)
+  end
+
+  def self.write(root : String, path : String, bytes : String) : Nil
+    Dir.mkdir_p(File.dirname(File.join(root, path)))
+    File.write(File.join(root, path), bytes)
+  end
+
+  def self.commit(root : String, message : String) : String
+    GitOracle.run(root, "add", ".")
+    GitOracle.run(root, "commit", "-qm", message)
+    GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
+  end
+
+  def self.fixture(root : String, conflict : Bool = false) : String
+    write(root, ".gitattributes", "*.txt text eol=crlf\n")
+    write(root, "file.txt", "base\r\n")
+    commit(root, "base")
+    GitOracle.run(root, "checkout", "-qb", "topic")
+    write(root, "file.txt", "topic\r\n")
+    write(root, "added.txt", "added\r\n")
+    commit(root, "topic")
+    GitOracle.run(root, "checkout", "-q", "main")
+    if conflict
+      write(root, "file.txt", "ours\r\n")
+      commit(root, "ours")
+    end
+    GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
+  end
+
+  def self.blob(repo : Git::Repository, path : String) : String
+    entry = repo.index_entries.find { |item| item.path == path && item.stage == 0 }.not_nil!
+    repo.read_object(entry.oid).data
+  end
+end
+
+describe "native replay EOL conversion" do
+  ["sha1", "sha256"].each do |format|
+    it "matches Git's #{format} cherry-pick and revert materialization" do
+      GitOracle.with_repo(format: format) do |root|
+        original = EOLReplaySpec.fixture(root)
+        GitOracle.run(root, "cherry-pick", "topic")
+        expected = File.read(File.join(root, "file.txt"))
+        expected_tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
+        GitOracle.run(root, "reset", "--hard", original)
+        repo = Git::Repository.new(root)
+        picked = repo.cherry_pick("topic", committer: EOLReplaySpec.signature)
+        picked.conflicts.should be_empty
+        File.read(File.join(root, "file.txt")).should eq(expected)
+        GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip.should eq(expected_tree)
+        EOLReplaySpec.blob(repo, "file.txt").should eq("topic\n")
+        repo.working_changes(include_untracked: false).should be_empty
+        repo.revert(picked.commit_oid.not_nil!, author: EOLReplaySpec.signature,
+          committer: EOLReplaySpec.signature)
+        File.read(File.join(root, "file.txt")).should eq("base\r\n")
+        EOLReplaySpec.blob(repo, "file.txt").should eq("base\n")
+      end
+    end
+
+    ["abort", "skip", "continue"].each do |action|
+      it "materializes #{format} conflict markers and #{action} with canonical stages" do
+        GitOracle.with_repo(format: format) do |root|
+          original = EOLReplaySpec.fixture(root, true)
+          repo = Git::Repository.new(root)
+          repo.cherry_pick("topic", committer: EOLReplaySpec.signature).conflicts.should eq(["file.txt"])
+          marker = File.read(File.join(root, "file.txt"))
+          marker.should contain("<<<<<<< HEAD\r\n")
+          marker.gsub("\r\n", "").includes?('\n').should be_false
+          repo.index_entries.select { |entry| entry.path == "file.txt" }.each do |entry|
+            repo.read_object(entry.oid).data.includes?('\r').should be_false
+          end
+          if action == "continue"
+            EOLReplaySpec.write(root, "file.txt", "resolved\r\n")
+            repo.stage_file("file.txt")
+            repo.cherry_pick.continue(committer: EOLReplaySpec.signature)
+            EOLReplaySpec.blob(repo, "file.txt").should eq("resolved\n")
+          else
+            action == "skip" ? repo.cherry_pick.skip : repo.cherry_pick.abort
+            File.read(File.join(root, "file.txt")).should eq("ours\r\n")
+            File.exists?(File.join(root, "added.txt")).should be_false
+            GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
+          end
+          repo.sequencer.state?.should be_nil
+          repo.working_changes(include_untracked: false).should be_empty
+        end
+      end
+    end
+
+    it "rejects expanded #{format} replay output before metadata or publication" do
+      GitOracle.with_repo(format: format) do |root|
+        original = EOLReplaySpec.fixture(root)
+        GitOracle.run(root, "checkout", "-q", "topic")
+        EOLReplaySpec.write(root, "large1.txt", "\n" * 200)
+        EOLReplaySpec.write(root, "large2.txt", "\n" * 200)
+        EOLReplaySpec.commit(root, "large")
+        GitOracle.run(root, "checkout", "-q", "main")
+        repo = Git::Repository.new(root)
+        index = File.read(File.join(root, ".git/index"))
+        expect_raises(Git::Error, /total byte budget/) do
+          repo.cherry_pick("topic", committer: EOLReplaySpec.signature,
+            max_object_bytes: 512, max_total_bytes: 512_i64)
+        end
+        File.read(File.join(root, ".git/index")).should eq(index)
+        GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original)
+        File.exists?(File.join(root, "large1.txt")).should be_false
+        repo.sequencer.state?.should be_nil
+      end
+    end
+  end
+end
diff --git a/src/git/workflow/rebase.cr b/src/git/workflow/rebase.cr
index 205cbb2..0739c6e 100644
--- a/src/git/workflow/rebase.cr
+++ b/src/git/workflow/rebase.cr
@@ -15,47 +15,47 @@ module Git
     end
 
     # The rebase in progress, or nil.
     def state? : State?
       @repository.rebase_state?
     end
 
     def in_progress? : Bool
       !state?.nil?
     end
 
     # `git rebase --continue`: commit the resolved step and replay the rest.
-    def continue(*, committer : Signature, max_object_bytes : Int32 = 8_388_608,
+    def continue(*, committer : Signature, config : Config? = nil, max_object_bytes : Int32 = 8_388_608,
                  max_index_bytes : Int32 = 8_388_608, max_total_bytes : Int64 = 67_108_864,
                  max_entries : Int32 = 10_000, check : Proc(Nil)? = nil) : Result
-      @repository.rebase_continue(committer: committer, max_object_bytes: max_object_bytes,
+      @repository.rebase_continue(committer: committer, config: config || @repository.config, max_object_bytes: max_object_bytes,
         max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
     end
 
     # `git rebase --skip`: drop the stopped commit and replay the rest.
-    def skip(*, committer : Signature, max_object_bytes : Int32 = 8_388_608,
+    def skip(*, committer : Signature, config : Config? = nil, max_object_bytes : Int32 = 8_388_608,
              max_index_bytes : Int32 = 8_388_608, max_total_bytes : Int64 = 67_108_864,
              max_entries : Int32 = 10_000, check : Proc(Nil)? = nil) : Result
-      @repository.rebase_skip(committer: committer, max_object_bytes: max_object_bytes,
+      @repository.rebase_skip(committer: committer, config: config || @repository.config, max_object_bytes: max_object_bytes,
         max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
     end
 
     # `git rebase --abort`: return the branch, index and worktree to where
     # the rebase started. Returns the paths it changed.
-    def abort(*, committer : Signature, max_object_bytes : Int32 = 8_388_608,
+    def abort(*, committer : Signature, config : Config? = nil, max_object_bytes : Int32 = 8_388_608,
               max_index_bytes : Int32 = 8_388_608, max_total_bytes : Int64 = 67_108_864,
               max_entries : Int32 = 10_000, check : Proc(Nil)? = nil) : Array(String)
-      @repository.rebase_abort(committer: committer, max_object_bytes: max_object_bytes,
+      @repository.rebase_abort(committer: committer, config: config || @repository.config, max_object_bytes: max_object_bytes,
         max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
     end
   end
 
   class Repository
     # The rebase in progress.
     def rebase : Rebase
       Rebase.new(self)
     end
   end
 end
diff --git a/src/git/workflow/rebase/continuation.cr b/src/git/workflow/rebase/continuation.cr
index 8cf8bc7..533c817 100644
--- a/src/git/workflow/rebase/continuation.cr
+++ b/src/git/workflow/rebase/continuation.cr
@@ -1,74 +1,77 @@
 module Git
   class Repository
-    protected def rebase_continue(*, committer : Signature,
+    protected def rebase_continue(*, committer : Signature, config : Config? = nil,
                                   max_object_bytes : Int32 = 8_388_608,
                                   max_index_bytes : Int32 = 8_388_608,
                                   max_total_bytes : Int64 = 67_108_864,
                                   max_entries : Int32 = 10_000,
                                   check : Proc(Nil)? = nil) : Rebase::Result
+      config ||= self.config
       state = rebase_state? || raise Error.new("no Git rebase in progress")
       item = sequencer_state? || raise Error.new("Git rebase has no stopped replay to continue")
       rebase_validate_item!(state, item)
       source = state.todo[state.next_index]
       new_head = sequencer_continue(committer: committer,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
       begin
         state = rebase_advance_state!(state, state.next_index + 1, new_head)
       rescue ex
         raise Rebase::PartialProgress.new(source, new_head, ex)
       end
-      rebase_run(state, committer: committer, max_object_bytes: max_object_bytes,
+      rebase_run(state, config: config, committer: committer, max_object_bytes: max_object_bytes,
         max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
     end
 
-    protected def rebase_skip(*, committer : Signature,
+    protected def rebase_skip(*, committer : Signature, config : Config? = nil,
                               max_object_bytes : Int32 = 8_388_608,
                               max_index_bytes : Int32 = 8_388_608,
                               max_total_bytes : Int64 = 67_108_864,
                               max_entries : Int32 = 10_000,
                               check : Proc(Nil)? = nil) : Rebase::Result
+      config ||= self.config
       state = rebase_state? || raise Error.new("no Git rebase in progress")
       item = sequencer_state? || raise Error.new("Git rebase has no stopped replay to skip")
       rebase_validate_item!(state, item)
-      sequencer_abort(max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
+      sequencer_abort(config: config, max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
       state = rebase_advance_state!(state, state.next_index + 1, state.expected_head)
-      rebase_run(state, committer: committer, max_object_bytes: max_object_bytes,
+      rebase_run(state, config: config, committer: committer, max_object_bytes: max_object_bytes,
         max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
     end
 
     # Abort the entire rebase, not merely the currently stopped replay. If an
     # item is conflicted, its single-item state is first restored to the last
     # successfully replayed HEAD; then the branch/index/worktree are restored
     # to the original pre-rebase commit.
-    protected def rebase_abort(*, committer : Signature,
+    protected def rebase_abort(*, committer : Signature, config : Config? = nil,
                                max_object_bytes : Int32 = 8_388_608,
                                max_index_bytes : Int32 = 8_388_608,
                                max_total_bytes : Int64 = 67_108_864,
                                max_entries : Int32 = 10_000,
                                check : Proc(Nil)? = nil) : Array(String)
+      config ||= self.config
       state = rebase_state? || raise Error.new("no Git rebase in progress")
       changed = [] of String
       if item = sequencer_state?
         rebase_validate_item!(state, item)
-        changed.concat(sequencer_abort(max_object_bytes: max_object_bytes,
+        changed.concat(sequencer_abort(config: config, max_object_bytes: max_object_bytes,
           max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
           max_entries: max_entries, check: check))
       end
       branch, current = head_ref_and_oid
       raise Error.new("Git rebase abort branch changed") unless branch == state.branch && current
       raise Error.new("Git rebase abort HEAD changed") unless {state.expected_head, state.original_head}.includes?(current)
       # HEAD may already be restored while the index still describes the
       # replayed tree. Reconcile all three components before clearing state.
-      changed.concat(rebase_move_branch!(state, state.expected_head, state.original_head,
+      changed.concat(rebase_move_branch!(state, state.expected_head, state.original_head, config: config,
         log: References::LogEntry.new(committer, "rebase (abort): returning to #{state.branch || state.original_head}"),
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, check: check, restore: true))
       refreshed = rebase_state? || raise Error.new("Git rebase state disappeared during abort")
       rebase_clear_state!(refreshed)
       changed.uniq
     end
   end
 end
diff --git a/src/git/workflow/rebase/initiate.cr b/src/git/workflow/rebase/initiate.cr
index 09791a9..54a240a 100644
--- a/src/git/workflow/rebase/initiate.cr
+++ b/src/git/workflow/rebase/initiate.cr
@@ -1,82 +1,83 @@
 module Git
   class Repository
     # Rebase the current symbolic branch (or detached HEAD) onto `upstream`,
     # or onto an explicit alternate commit while still selecting commits
     # relative to `upstream`. The selected branch-only history must be a linear
     # first-parent chain. Clean items replay synchronously; conflicts leave
     # REBASE_HEAD plus the normal index stages and can be resumed with
     # rebase_continue/skip/abort.
     def rebase(upstream : String, *, committer : Signature,
-               onto : String? = nil, keep_empty : Bool = false,
+               onto : String? = nil, keep_empty : Bool = false, config : Config? = nil,
                max_commits : Int32 = 512, max_graph_nodes : Int32 = 16_384,
                max_object_bytes : Int32 = 8_388_608,
                max_index_bytes : Int32 = 8_388_608,
                max_total_bytes : Int64 = 67_108_864,
                max_entries : Int32 = 10_000,
                check : Proc(Nil)? = nil) : Rebase::Result
       require_worktree!
+      config ||= self.config
       raise ArgumentError.new("invalid Git rebase budgets") if max_commits < 0 || max_commits > 512 ||
                                                                max_graph_nodes < 1 || max_object_bytes < 128 ||
                                                                max_index_bytes < 128 || max_total_bytes < max_object_bytes ||
                                                                max_entries < 1 || max_entries > @max_search_entries
       check!
       raise Error.new("Git rebase unsupported with linked worktrees") unless @git_dir == @common &&
                                                                              (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
       raise Error.new("Git rebase refuses in-progress merge") if merge_state?
       raise Error.new("Git rebase refuses in-progress sequencer operation") if sequencer_state?
       raise Error.new("Git rebase already in progress") if rebase_state?
       branch, original_head = head_ref_and_oid
       unless original_head && (branch.nil? || branch.starts_with?("refs/heads/"))
         raise Error.new("Git rebase requires an existing branch or detached HEAD")
       end
       upstream_oid = History.resolve_commit(self, upstream, max_object_bytes, check)
       onto_oid = History.resolve_commit(self, onto || upstream, max_object_bytes, check)
       base, todo = rebase_plan(original_head, upstream_oid,
         max_commits: max_commits, max_graph_nodes: max_graph_nodes,
         max_object_bytes: max_object_bytes, check: check)
 
-      rebase_preflight_clean!(original_head, max_object_bytes: max_object_bytes,
+      rebase_preflight_clean!(original_head, config: config, max_object_bytes: max_object_bytes,
         max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
 
       # A branch already based directly on the requested upstream is already
       # up to date unless an explicit --onto-like destination was requested.
       if onto.nil? && base == upstream_oid
         return Rebase::Result.new(branch, original_head, onto_oid, original_head,
           0, 0, [] of String, true)
       end
       state = Rebase::State.new(branch, original_head, upstream_oid, onto_oid,
         todo, 0, onto_oid, keep_empty)
       rebase_write_initial_state!(state)
       write_orig_head(original_head)
       if original_head != onto_oid
         begin
-          rebase_move_branch!(state, original_head, onto_oid,
+          rebase_move_branch!(state, original_head, onto_oid, config: config,
             log: References::LogEntry.new(committer, "rebase (start): checkout #{onto || upstream}"),
             max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
             max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
         rescue ex : Rebase::PartialPublication
           raise ex
         rescue ex
           # No publication began: do not strand an otherwise untouched branch
           # in synthetic rebase state because, for example, a foreign index
           # lock prevented the base move from starting.
           if head_ref_and_oid == {branch, original_head} && rebase_state? == state && sequencer_state?.nil?
             rebase_clear_state!(state)
           end
           raise ex
         end
       end
-      rebase_run(state, committer: committer, max_object_bytes: max_object_bytes,
+      rebase_run(state, config: config, committer: committer, max_object_bytes: max_object_bytes,
         max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
     end
 
     # Durable outer rebase plan/progress. Per-item conflict state is exposed by
     # `sequencer_state?` and must have kind Rebase while a replay is stopped.
     protected def rebase_state? : Rebase::State?
       check!
       parent = DescriptorPath::Directory.open(@git_dir)
       child = nil.as(DescriptorPath::Directory?)
       begin
         return nil unless parent.stat?("rebase-merge")
diff --git a/src/git/workflow/rebase/metadata.cr b/src/git/workflow/rebase/metadata.cr
index be827cf..12fa6a9 100644
--- a/src/git/workflow/rebase/metadata.cr
+++ b/src/git/workflow/rebase/metadata.cr
@@ -51,24 +51,30 @@ module Git
       raise Error.new("Git rebase state changed during cleanup") unless rebase_state? == state
       raise Error.new("Git rebase replay still active during cleanup") if sequencer_state?
       parent = DescriptorPath::Directory.open(@git_dir)
       child = nil.as(DescriptorPath::Directory?)
       begin
         child = parent.open_directory("rebase-merge")
         {"head-name", "orig-head", "upstream", "onto", "git-rebase-todo", "state"}.each do |name|
           raise Error.new("Git rebase metadata missing during cleanup") unless child.stat?(name)
           child.unlink(name)
           child.sync
         end
         raise Error.new("Git rebase progress lock remains during cleanup") if child.stat?("state.lock")
+        {"worktree-restore", "worktree-restore.required"}.each do |name|
+          if child.stat?(name)
+            child.unlink(name)
+            child.sync
+          end
+        end
         child.close
         child = nil
         parent.rmdir("rebase-merge")
         parent.sync
       ensure
         child.try &.close
         parent.close
       end
     end
 
     private def rebase_read_file!(directory : DescriptorPath::Directory,
                                   name : String, max_bytes : Int32) : String
diff --git a/src/git/workflow/rebase/preflight.cr b/src/git/workflow/rebase/preflight.cr
index b99e9c6..f2129be 100644
--- a/src/git/workflow/rebase/preflight.cr
+++ b/src/git/workflow/rebase/preflight.cr
@@ -19,26 +19,28 @@ module Git
         parent = entry.parents.first? || raise Error.new("Git rebase base is not on the first-parent chain")
         reverse << cursor
         cursor = parent
       end
       {base, reverse.reverse}
     end
 
     private def rebase_preflight_clean!(head_oid : String, *,
                                         max_object_bytes : Int32,
                                         max_index_bytes : Int32,
                                         max_total_bytes : Int64,
                                         max_entries : Int32,
-                                        check : Proc(Nil)?) : Nil
+                                        check : Proc(Nil)?, config : Config) : Nil
       tree = read_commit(head_oid, max_bytes: max_object_bytes, check: check).tree
       expected = Checkout.tree_files(self, tree, max_object_bytes: max_object_bytes,
         max_files: max_entries, check: check, allow_symlinks: true)
       current = @index.entries(max_index_bytes) { check.try &.call }
       raise Error.new("Git rebase requires index equal to HEAD") unless current.size == expected.size && current.all? do |entry|
                                                                           entry.stage == 0 && !entry.intent && !entry.skip_worktree && !entry.assume_unchanged &&
                                                                           expected[entry.path]?.try { |state| state.mode == entry.mode && state.oid == entry.oid } == true
                                                                         end
       Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
-        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
+        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true,
+        conversion: Conversion.new(self, config: config, max_bytes: max_object_bytes,
+          max_index_bytes: max_index_bytes, check: check))
     end
   end
 end
diff --git a/src/git/workflow/rebase/publication.cr b/src/git/workflow/rebase/publication.cr
index 09cd2dd..84cfd1f 100644
--- a/src/git/workflow/rebase/publication.cr
+++ b/src/git/workflow/rebase/publication.cr
@@ -1,120 +1,183 @@
 module Git
   class Repository
     private def rebase_move_branch!(state : Rebase::State, from_oid : String, to_oid : String, *,
                                     log : References::LogEntry,
                                     max_object_bytes : Int32, max_index_bytes : Int32,
                                     max_total_bytes : Int64, max_entries : Int32,
-                                    check : Proc(Nil)?, restore : Bool = false) : Array(String)
+                                    check : Proc(Nil)?, config : Config, restore : Bool = false) : Array(String)
       return [] of String if from_oid == to_oid && !restore
       raise Error.new("Git rebase move state changed") unless rebase_state? == state
       branch, observed_head = head_ref_and_oid
       raise Error.new("Git rebase move HEAD changed") unless branch == state.branch &&
                                                              (observed_head == from_oid || (restore && observed_head == to_oid))
       old_tree = read_commit(from_oid, max_bytes: max_object_bytes, check: check).tree
       target_tree = read_commit(to_oid, max_bytes: max_object_bytes, check: check).tree
       old = Checkout.tree_files(self, old_tree, max_object_bytes: max_object_bytes,
         max_files: max_entries, check: check, allow_symlinks: true)
       desired = Checkout.tree_files(self, target_tree, max_object_bytes: max_object_bytes,
         max_files: max_entries, check: check, allow_symlinks: true)
+      checksum = @index.snapshot_checksum(max_index_bytes)
       current = @index.entries(max_index_bytes) { check.try &.call }
       unless Merge.index_matches_head?(current, old) || (restore && Merge.index_matches_head?(current, desired))
         raise Error.new("Git rebase move requires index equal to HEAD")
       end
       Checkout.require_tree_paths!(old.keys, "Git rebase predecessor")
       Checkout.require_tree_paths!(desired.keys, "Git rebase destination")
+      conversion = Conversion.new(self, config: config, max_bytes: max_object_bytes,
+        max_index_bytes: max_index_bytes, check: check)
+      output = Conversion.new(self, config: config, attribute_tree: target_tree,
+        max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
+      raw_desired = restore ? output.raw_states(desired, max_total_bytes: max_total_bytes,
+        operation: "Git rebase move") : {} of String => Checkout::FileState
+      restoration_data = nil.as(String?)
+      restoration_persisted = false
+      raw_old = if restore
+                  Conversion.new(self, config: config, attribute_tree: old_tree,
+                    max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
+                    .raw_states(old, max_total_bytes: max_total_bytes, operation: "Git rebase abort")
+                else
+                  {} of String => Checkout::FileState
+                end
+      if restore
+        parent = DescriptorPath::Directory.open(@git_dir)
+        child = nil.as(DescriptorPath::Directory?)
+        begin
+          child = parent.open_directory("rebase-merge")
+          raise Error.new("Git rebase move state changed") unless rebase_state? == state
+          restoration_persisted = !!child.not_nil!.stat?("worktree-restore")
+          restoration_data = replay_recovery!(child.not_nil!, "worktree-restore",
+            "#{state.branch}:#{state.original_head}:#{state.onto}:#{state.next_index}:#{from_oid}:#{to_oid}",
+            raw_old, raw_desired, max_bytes: max_index_bytes, max_entries: max_entries, persist: false)
+        ensure
+          child.try &.close
+          parent.close
+        end
+      end
+      clean_observations = {} of String => Checkout::FileState
       view = if restore
                # An interrupted abort can leave either tree's files or either
                # complete index image. Admit only those exact bytes, including
                # restored files that have not yet entered the index.
-               receipt = Merge::Recovery::Receipt.new(old.keys, old)
-               observed = Merge::Recovery.observe(self, current, desired, receipt,
+               receipt = Merge::Recovery::Receipt.new(old.keys, raw_old)
+               observed = Merge::Recovery.observe(self, current, raw_desired, receipt,
                  max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes,
                  max_entries: max_entries, check: check)
                observed.observations.each do |path, actual|
-                 if actual && actual != old[path]? && actual != desired[path]?
+                 if actual && actual != raw_old[path]? && actual != raw_desired[path]?
                    raise Error.new("Git rebase abort refuses changed worktree content: #{path}")
                  end
                end
                observed.preflight!(@root, desired.keys, max_entries)
                observed
              else
-               Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
-                 max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
+               clean_observations = Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
+                 max_total_bytes: max_total_bytes, check: check, allow_symlinks: true, conversion: conversion)
                Checkout.require_transition_destinations!(@root, old.keys, desired.keys,
                  max_entries: max_entries)
                nil
              end
-      observations = view ? view.observations : old.transform_values { |value| value.as(Checkout::FileState?) }
-      changed = (observations.keys + desired.keys).uniq.sort.select { |path| observations[path]? != desired[path]? }
+      observations = view ? view.observations : clean_observations.transform_values { |value| value.as(Checkout::FileState?) }
+      changed = if restore
+                  (observations.keys + desired.keys).uniq.sort.select { |path| observations[path]? != raw_desired[path]? }
+                else
+                  (old.keys + desired.keys).uniq.sort.select { |path| old[path]? != desired[path]? }
+                end
       raise Error.new("Git rebase move entry budget exceeded") if changed.size > max_entries
       edits = [] of Index::Edit
       writes = [] of Checkout::Write
       removes = [] of String
       transferred = view.try(&.bytes) || 0_i64
       changed.each do |path|
         check.try &.call
         if next_entry = desired[path]?
           kind, raw = object(next_entry.oid, max_object_bytes) { check.try &.call }
           raise Error.new("Git rebase move entry is not a blob") unless kind == "blob"
           transferred += raw.bytesize
           raise Error.new("Git rebase move total byte budget exceeded") if transferred > max_total_bytes
           writes << Checkout::Write.new(path, next_entry.mode, next_entry.oid, raw)
           edits << Index::Put.new(path, next_entry.mode, next_entry.oid)
         else
           removes << path
           edits << Index::Remove.new(path)
         end
       end
+      writes = output.materialize(writes, max_total_bytes: max_total_bytes - (view.try(&.bytes) || 0_i64),
+        operation: "Git rebase move")
       if restore
         edits = IndexRestore.edits(current, IndexRestore.source_entries(self, target_tree,
           max_object_bytes: max_object_bytes, max_entries: max_entries, check: check), nil)
       end
       image = edits.empty? ? nil : @index.prepare_changes(edits,
         max_bytes: max_index_bytes, max_entries: max_entries, check: check)
       write_paths = writes.map(&.path)
       blocking_removes, trailing_removes = removes.partition do |path|
         write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
       end
       transition_dirs = view ? view.transition_directories(desired.keys) : Checkout.transition_directories(old.keys, desired.keys)
-      checksum = @index.snapshot_checksum(max_index_bytes)
       admin = DescriptorPath::Directory.open(@git_dir)
       index_lock = nil.as(IO::FileDescriptor?)
       started = false
       ref_published = false
       index_published = false
       changed_paths = [] of String
       begin
         index_lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
         guard = -> do
           check.try &.call
           raise Error.new("Git rebase move state changed") unless rebase_state? == state
+          if restoration_persisted
+            parent = DescriptorPath::Directory.open(@git_dir)
+            child = nil.as(DescriptorPath::Directory?)
+            begin
+              child = parent.open_directory("rebase-merge")
+              raise Error.new("Git rebase restoration metadata changed") unless Merge::Recovery.read(child.not_nil!, "worktree-restore", max_index_bytes) == restoration_data
+            ensure
+              child.try &.close
+              parent.close
+            end
+          end
           raise Error.new("Git rebase move HEAD changed") unless head_ref_and_oid == {state.branch, observed_head}
           raise Error.new("Git rebase move index changed") unless @index.snapshot_checksum(max_index_bytes) == checksum
         end
         guard.call
         if view
           view.preflight!(@root, desired.keys, max_entries)
         else
           Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
-            max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
+            max_total_bytes: max_total_bytes, check: check, allow_symlinks: true, conversion: conversion)
           Checkout.require_transition_destinations!(@root, old.keys, desired.keys,
             max_entries: max_entries)
         end
         if planned = image
           raise Error.new("Git rebase move index image diverged") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
           index_lock.write(planned.data.to_slice)
           index_lock.flush
           index_lock.fsync
         end
+        if restore
+          parent = DescriptorPath::Directory.open(@git_dir)
+          child = nil.as(DescriptorPath::Directory?)
+          begin
+            child = parent.open_directory("rebase-merge")
+            replay_recovery!(child.not_nil!, "worktree-restore",
+              "#{state.branch}:#{state.original_head}:#{state.onto}:#{state.next_index}:#{from_oid}:#{to_oid}",
+              raw_old, raw_desired, max_bytes: max_index_bytes, max_entries: max_entries)
+            restoration_persisted = true
+          ensure
+            child.try &.close
+            parent.close
+          end
+          guard.call
+        end
         blocking_removes.each do |path|
           started = true
           Checkout.remove(@root, path, observations[path].not_nil!, format: @object_format, check: guard)
           changed_paths << path
         end
         transition_dirs.each do |directory|
           started = true
           Checkout.remove_empty_directory(@root, directory, check: guard)
         end
         writes.each_with_index do |write, sequence|
           started = true
           Checkout.write(@root, write, sequence, expected_old: observations[write.path]?,
diff --git a/src/git/workflow/rebase/replay.cr b/src/git/workflow/rebase/replay.cr
index ed2dbdb..fc114ec 100644
--- a/src/git/workflow/rebase/replay.cr
+++ b/src/git/workflow/rebase/replay.cr
@@ -1,53 +1,53 @@
 module Git
   class Repository
     private def rebase_run(initial : Rebase::State, *, committer : Signature,
                            max_object_bytes : Int32, max_index_bytes : Int32,
                            max_total_bytes : Int64, max_entries : Int32,
-                           check : Proc(Nil)?) : Rebase::Result
+                           check : Proc(Nil)?, config : Config) : Rebase::Result
       state = initial
       loop do
         branch, current = head_ref_and_oid
         raise Error.new("Git rebase branch changed") unless branch == state.branch && current == state.expected_head
         raise Error.new("Git rebase progress changed") unless rebase_state? == state
         if state.next_index >= state.todo.size
           raise Error.new("Git rebase sequencer state remains at completion") if sequencer_state?
           final_head = state.expected_head
           rebase_clear_state!(state)
           return Rebase::Result.new(state.branch, state.original_head, state.onto,
             final_head, state.todo.size, state.todo.size, [] of String, true)
         end
         raise Error.new("Git rebase unexpected stopped sequencer") if sequencer_state?
         source = state.todo[state.next_index]
         # Git keeps commits whose own tree was already empty relative to their
         # parent; keep_empty only controls replays that become empty on `onto`.
         item = Sequencer.read_source(self, source, max_object_bytes, check)
         originally_empty = if parent = item.parents.first?
                              item.tree == read_commit(parent, max_bytes: max_object_bytes, check: check).tree
                            else
                              false
                            end
         result = begin
           sequencer_start(Sequencer::Kind::Rebase, source, committer: committer,
-            author: nil, message: nil, mainline: nil, allow_empty: state.keep_empty || originally_empty,
+            author: nil, message: nil, mainline: nil, allow_empty: state.keep_empty || originally_empty, config: config,
             max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
             max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
         rescue ex : Sequencer::EmptyCommit
           # Default non-interactive rebase drops a replay that has become empty.
           # The single-item state remains durable until it is explicitly
           # restored, so skip uses the same recovery path as a user request.
           raise ex if state.keep_empty
           item = sequencer_state? || raise Error.new("Git rebase empty replay state missing")
           rebase_validate_item!(state, item)
-          sequencer_abort(max_object_bytes: max_object_bytes,
+          sequencer_abort(config: config, max_object_bytes: max_object_bytes,
             max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
             max_entries: max_entries, check: check)
           state = rebase_advance_state!(state, state.next_index + 1, state.expected_head)
           next
         end
         unless result.conflicts.empty?
           return Rebase::Result.new(state.branch, state.original_head, state.onto,
             state.expected_head, state.next_index, state.todo.size,
             result.conflicts, false)
         end
         new_head = result.commit_oid || raise Error.new("Git rebase clean replay did not commit")
         begin
diff --git a/src/git/workflow/sequencer.cr b/src/git/workflow/sequencer.cr
index 9b36af0..c07667b 100644
--- a/src/git/workflow/sequencer.cr
+++ b/src/git/workflow/sequencer.cr
@@ -1,22 +1,23 @@
 require "set"
 
 require "./sequencer/values"
 require "./sequencer/source"
 require "./sequencer/initiate"
 require "./sequencer/state"
 require "./sequencer/continuation"
 require "./sequencer/abort"
 require "./sequencer/replay"
 require "./sequencer/metadata"
+require "./sequencer/recovery"
 
 module Git
   # A commit replay in progress (Git's sequencer): a cherry-pick, a revert or
   # the stopped step of a rebase. Repository#cherry_pick and #revert without
   # arguments give a handle limited to that kind; Repository#sequencer gives
   # one for whichever is in progress.
   struct Sequencer
     def initialize(@repository : Repository, @kind : Kind? = nil)
     end
 
     # The operation in progress, or nil (also nil when one of another kind
     # than this handle's is in progress).
@@ -39,40 +40,40 @@ module Git
     # `--continue`: commit the resolved index with the recorded author and
     # message (or message). Returns the new commit's ID.
     def continue(*, committer : Signature, message : String? = nil,
                  max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
                  check : Proc(Nil)? = nil) : String
       require_state!
       @repository.sequencer_continue(committer: committer, message: message,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
     end
 
     # `--abort`: restore the branch, index and worktree from before the
     # operation. Returns the paths it changed.
-    def abort(*, max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
+    def abort(*, config : Config? = nil, max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
               max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
               check : Proc(Nil)? = nil) : Array(String)
       require_state!
-      @repository.sequencer_abort(max_object_bytes: max_object_bytes,
+      @repository.sequencer_abort(config: config || @repository.config, max_object_bytes: max_object_bytes,
         max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
     end
 
     # `--skip`: drop the current commit. With a single commit in the
     # sequence this restores the state from before the operation, as abort
     # does.
-    def skip(*, max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
+    def skip(*, config : Config? = nil, max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
              max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
              check : Proc(Nil)? = nil) : Array(String)
-      abort(max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
+      abort(config: config || @repository.config, max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
     end
 
     private def require_state! : Nil
       label = @kind.try { |kind| kind.cherry_pick? ? "cherry-pick" : kind.revert? ? "revert" : "rebase" } || "sequencer operation"
       state = @repository.sequencer_state? || raise Error.new("no Git #{label} in progress")
       if (kind = @kind) && state.kind != kind
         raise Error.new("Git sequencer operation is not a #{label}")
       end
     end
   end
 
diff --git a/src/git/workflow/sequencer/abort.cr b/src/git/workflow/sequencer/abort.cr
index 75e984d..f35d4fd 100644
--- a/src/git/workflow/sequencer/abort.cr
+++ b/src/git/workflow/sequencer/abort.cr
@@ -1,106 +1,127 @@
 module Git
   class Repository
     # Restore the original HEAD tree/index/worktree and clear single-item
     # sequencer metadata. Resolution-time unrelated staged paths are refused.
     # D/F transitions are restored with the same collision planner used by
     # checkout and merge; untracked content is never recursively removed.
-    protected def sequencer_abort(*, max_object_bytes : Int32 = 8_388_608,
+    protected def sequencer_abort(*, config : Config? = nil, max_object_bytes : Int32 = 8_388_608,
                                   max_index_bytes : Int32 = 8_388_608,
                                   max_total_bytes : Int64 = 67_108_864,
                                   max_entries : Int32 = 10_000,
                                   check : Proc(Nil)? = nil) : Array(String)
       require_worktree!
+      config ||= self.config
       state = sequencer_state? || raise Error.new("no Git sequencer operation in progress")
       raise Error.new("Git sequencer abort HEAD changed") unless head_ref_and_oid == {state.branch, state.original_head}
       original_tree = read_commit(state.original_head, max_bytes: max_object_bytes, check: check).tree
       original = Checkout.tree_files(self, original_tree, max_object_bytes: max_object_bytes,
         max_files: max_entries, check: check, allow_symlinks: true)
+      conversion = Conversion.new(self, config: config, attribute_tree: original_tree,
+        max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
+      raw_original = conversion.raw_states(original, max_total_bytes: max_total_bytes,
+        operation: "Git sequencer abort")
       source = Sequencer.read_source(self, state.source, max_object_bytes, check)
       source_files = Checkout.tree_files(self, source.tree, max_object_bytes: max_object_bytes,
         max_files: max_entries, check: check, allow_symlinks: true)
       parent_files = if parent_oid = state.parent
                        parent_tree = read_commit(parent_oid, max_bytes: max_object_bytes, check: check).tree
                        Checkout.tree_files(self, parent_tree, max_object_bytes: max_object_bytes,
                          max_files: max_entries, check: check, allow_symlinks: true)
                      else
                        {} of String => Checkout::FileState
                      end
       manifest_admin = DescriptorPath::Directory.open(@git_dir)
       begin
         relocation_data = Merge::Recovery.read(manifest_admin, "CRYSTAL_SEQUENCER_PATHS", max_index_bytes)
+        restoration_persisted = !!manifest_admin.stat?("CRYSTAL_SEQUENCER_RESTORE")
+        restoration_data = replay_recovery!(manifest_admin, "CRYSTAL_SEQUENCER_RESTORE",
+          "#{state.kind}:#{state.original_head}:#{state.source}",
+          {} of String => Checkout::FileState, raw_original,
+          max_bytes: max_index_bytes, max_entries: max_entries, persist: false)
       ensure
         manifest_admin.close
       end
       receipt = Merge::Recovery.decode(relocation_data, state.original_head, state.source,
         @object_format, max_index_bytes, max_entries)
       allowed = (original.keys + source_files.keys + parent_files.keys + receipt.paths + receipt.outputs.keys).uniq
+      snapshot = @index.snapshot_checksum(max_index_bytes)
       current = @index.entries(max_index_bytes) { check.try &.call }
       raise Error.new("Git sequencer abort refuses unrelated staged paths") if current.any? { |entry| !allowed.includes?(entry.path) }
       Checkout.require_tree_paths!(original.keys, "Git sequencer abort target")
-      view = Merge::Recovery.observe(self, current, original, receipt,
+      view = Merge::Recovery.observe(self, current, raw_original, receipt,
         max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
       view.preflight!(@root, original.keys, max_entries)
       desired = IndexRestore.source_entries(self, original_tree,
         max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
       edits = IndexRestore.edits(current, desired, nil)
       image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
         max_entries: max_entries * 3, check: check)
-      snapshot = @index.snapshot_checksum(max_index_bytes)
       observations = view.observations
       writes = [] of Checkout::Write
       removals = [] of {String, Checkout::FileState}
       total = view.bytes
       observations.keys.sort.each do |path|
         check.try &.call
         observed = observations[path]
         if goal = original[path]?
-          next if goal == observed
+          next if raw_original[path] == observed
           kind, raw = object(goal.oid, max_object_bytes) { check.try &.call }
           raise Error.new("Git sequencer abort source not blob") unless kind == "blob"
           total += raw.bytesize
           raise Error.new("Git sequencer abort total byte budget exceeded") if total > max_total_bytes
           writes << Checkout::Write.new(path, goal.mode, goal.oid, raw)
         elsif observed_state = observed
           removals << {path, observed_state}
         end
       end
+      writes = conversion.materialize(writes, max_total_bytes: max_total_bytes - view.bytes,
+        operation: "Git sequencer abort")
       write_paths = writes.map(&.path)
       blocking_removals, trailing_removals = removals.partition do |path, _state|
         write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
       end
       transition_dirs = view.transition_directories(original.keys)
       admin = DescriptorPath::Directory.open(@git_dir)
       lock = nil.as(IO::FileDescriptor?)
       started = false
       index_published = false
       cleanup_started = false
       changed = [] of String
       begin
         lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
         guard = -> do
           check.try &.call
           raise Error.new("Git sequencer abort recovery metadata changed") unless Merge::Recovery.read(admin, "CRYSTAL_SEQUENCER_PATHS", max_index_bytes) == relocation_data
+          if restoration_persisted
+            raise Error.new("Git sequencer abort restoration metadata changed") unless Merge::Recovery.read(admin, "CRYSTAL_SEQUENCER_RESTORE", max_index_bytes) == restoration_data
+          end
           raise Error.new("Git sequencer abort state changed") unless head_ref_and_oid == {state.branch, state.original_head} &&
                                                                       sequencer_state? == state &&
                                                                       @index.snapshot_checksum(max_index_bytes) == snapshot
         end
         guard.call
         view.preflight!(@root, original.keys, max_entries)
         if planned = image
           lock.write(planned.data.to_slice)
           lock.flush
           lock.fsync
         end
+        replay_recovery!(admin, "CRYSTAL_SEQUENCER_RESTORE",
+          "#{state.kind}:#{state.original_head}:#{state.source}",
+          {} of String => Checkout::FileState, raw_original,
+          max_bytes: max_index_bytes, max_entries: max_entries)
+        restoration_persisted = true
+        guard.call
         blocking_removals.each do |path, previous|
           started = true
           Checkout.remove(@root, path, previous, format: @object_format, check: guard)
           changed << path
         end
         transition_dirs.each do |directory|
           started = true
           Checkout.remove_empty_directory(@root, directory, check: guard)
         end
         writes.each_with_index do |write, sequence|
           started = true
           Checkout.write(@root, write, sequence, expected_old: observations[write.path],
diff --git a/src/git/workflow/sequencer/initiate.cr b/src/git/workflow/sequencer/initiate.cr
index a7adc30..1618eb0 100644
--- a/src/git/workflow/sequencer/initiate.cr
+++ b/src/git/workflow/sequencer/initiate.cr
@@ -1,38 +1,38 @@
 module Git
   class Repository
     # Apply one commit's parent->commit delta to HEAD and create a new
     # first-parent commit. A source merge commit requires mainline: 1..N.
     # The source author/date is preserved; the caller supplies the new
     # committer identity/date. Conflicts leave standard CHERRY_PICK_HEAD state.
     def cherry_pick(source : String, *, committer : Signature,
                     message : String? = nil, mainline : Int32? = nil,
-                    allow_empty : Bool = false,
+                    allow_empty : Bool = false, config : Config? = nil,
                     max_object_bytes : Int32 = 8_388_608,
                     max_index_bytes : Int32 = 8_388_608,
                     max_total_bytes : Int64 = 67_108_864,
                     max_entries : Int32 = 10_000,
                     check : Proc(Nil)? = nil) : Sequencer::Result
       sequencer_start(Sequencer::Kind::CherryPick, source, committer: committer,
-        author: nil, message: message, mainline: mainline, allow_empty: allow_empty,
+        author: nil, message: message, mainline: mainline, allow_empty: allow_empty, config: config || self.config,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
     end
 
     # Apply the inverse commit delta to HEAD. For a merge commit, mainline
     # identifies the parent whose side of the merge is retained. Root commits
     # are supported: reverting one applies commit->empty.
     def revert(source : String, *, author : Signature, committer : Signature,
                message : String? = nil, mainline : Int32? = nil,
-               allow_empty : Bool = false,
+               allow_empty : Bool = false, config : Config? = nil,
                max_object_bytes : Int32 = 8_388_608,
                max_index_bytes : Int32 = 8_388_608,
                max_total_bytes : Int64 = 67_108_864,
                max_entries : Int32 = 10_000,
                check : Proc(Nil)? = nil) : Sequencer::Result
       sequencer_start(Sequencer::Kind::Revert, source, committer: committer,
-        author: author, message: message, mainline: mainline, allow_empty: allow_empty,
+        author: author, message: message, mainline: mainline, allow_empty: allow_empty, config: config || self.config,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
     end
   end
 end
diff --git a/src/git/workflow/sequencer/metadata.cr b/src/git/workflow/sequencer/metadata.cr
index ca94431..89eda03 100644
--- a/src/git/workflow/sequencer/metadata.cr
+++ b/src/git/workflow/sequencer/metadata.cr
@@ -1,24 +1,25 @@
 module Git
   class Repository
     private def validate_sequencer_message!(message : String) : Nil
       raise Error.new("Git sequencer message invalid") if message.includes?('\0') || message.bytesize > 65_536
     end
 
     private def sequencer_metadata_exists? : Bool
       admin = DescriptorPath::Directory.open(@git_dir)
       begin
         {"CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "MERGE_MSG", "CRYSTAL_SEQUENCER_ORIG",
          "CRYSTAL_SEQUENCER_PARENT", "CRYSTAL_SEQUENCER_AUTHOR",
-         "CRYSTAL_SEQUENCER_ALLOW_EMPTY", "CRYSTAL_SEQUENCER_PATHS"}.any? { |name| !!admin.stat?(name) }
+         "CRYSTAL_SEQUENCER_ALLOW_EMPTY", "CRYSTAL_SEQUENCER_PATHS", "CRYSTAL_SEQUENCER_RESTORE",
+         "CRYSTAL_SEQUENCER_RESTORE.lock", "CRYSTAL_SEQUENCER_RESTORE.required"}.any? { |name| !!admin.stat?(name) }
       ensure
         admin.close
       end
     end
 
     private def sequencer_read_metadata?(admin : DescriptorPath::Directory, name : String) : String?
       io = admin.open_file?(name, LibC::O_RDONLY | LibC::O_NONBLOCK)
       return nil unless io
       begin
         raise Error.new("Git sequencer metadata not a regular file") unless io.info.type.file?
         raise Error.new("Git sequencer metadata budget exceeded") if io.info.size > 65_536
         contents = IO::Memory.new
@@ -65,15 +66,21 @@ module Git
         if name == Sequencer.head_name(state.kind) || !{"CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD"}.includes?(name)
           raise Error.new("Git sequencer metadata missing during cleanup") unless admin.stat?(name)
           admin.unlink(name)
           admin.sync
         else
           raise Error.new("unexpected Git sequencer head file") if admin.stat?(name)
         end
       end
       if admin.stat?("CRYSTAL_SEQUENCER_PATHS")
         admin.unlink("CRYSTAL_SEQUENCER_PATHS")
         admin.sync
       end
+      {"CRYSTAL_SEQUENCER_RESTORE", "CRYSTAL_SEQUENCER_RESTORE.required"}.each do |name|
+        if admin.stat?(name)
+          admin.unlink(name)
+          admin.sync
+        end
+      end
     end
   end
 end
diff --git a/src/git/workflow/sequencer/recovery.cr b/src/git/workflow/sequencer/recovery.cr
new file mode 100644
index 0000000..efe4e43
--- /dev/null
+++ b/src/git/workflow/sequencer/recovery.cr
@@ -0,0 +1,60 @@
+module Git
+  class Repository
+    # Bind exact restoration identities before the first worktree mutation.
+    # A retry may verify these identities but cannot select new ownership by
+    # changing conversion configuration or attribute sources.
+    private def replay_recovery!(directory : DescriptorPath::Directory, name : String,
+                                 identity : String,
+                                 predecessor : Hash(String, Checkout::FileState),
+                                 target : Hash(String, Checkout::FileState), *,
+                                 max_bytes : Int32, max_entries : Int32, persist : Bool = true) : String
+      magic = "\0git-replay-raw-v1\0"
+      raise Error.new("Git replay recovery entry budget exceeded") if predecessor.size > max_entries || target.size > max_entries
+      fields = [identity, predecessor.size.to_s, target.size.to_s]
+      {predecessor, target}.each do |states|
+        states.keys.sort.each do |path|
+          state = states[path]
+          PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
+          raise Error.new("Git replay recovery mode invalid") unless {"100644", "100755", "120000"}.includes?(state.mode)
+          ObjectId.valid!(state.oid, @object_format)
+          fields.concat([path, state.mode, state.oid])
+        end
+      end
+      expected = magic + fields.join('\0')
+      raise Error.new("Git replay recovery byte budget exceeded") if expected.bytesize > max_bytes
+      existing = Merge::Recovery.read(directory, name, max_bytes)
+      required = Merge::Recovery.read(directory, "#{name}.required", 128)
+      raise Error.new("Git required replay restoration metadata missing") if required && !existing
+      raise Error.new("Git replay restoration marker invalid") if required && required != "raw-v1\n"
+      raise Error.new("Git replay restoration identities changed") if existing && existing != expected
+      return expected unless persist
+      unless existing
+        lock_name = "#{name}.lock"
+        lock = directory.open_file(lock_name, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
+        begin
+          lock.write(expected.to_slice)
+          lock.flush
+          lock.fsync
+          raise Error.new("Git replay recovery metadata appeared") if directory.stat?(name)
+          directory.rename(lock_name, name)
+          directory.sync
+        ensure
+          directory.unlink(lock_name) if directory.same_inode?(lock_name, lock)
+          lock.close unless lock.closed?
+        end
+      end
+      unless required
+        marker = directory.open_file("#{name}.required", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
+        begin
+          marker.write("raw-v1\n".to_slice)
+          marker.flush
+          marker.fsync
+        ensure
+          marker.close unless marker.closed?
+        end
+        directory.sync
+      end
+      expected
+    end
+  end
+end
diff --git a/src/git/workflow/sequencer/replay.cr b/src/git/workflow/sequencer/replay.cr
index 7ef44ed..2fe45d3 100644
--- a/src/git/workflow/sequencer/replay.cr
+++ b/src/git/workflow/sequencer/replay.cr
@@ -1,21 +1,23 @@
 module Git
   class Repository
     private def sequencer_start(kind : Sequencer::Kind, source_expression : String, *,
                                 committer : Signature, author : Signature?, message : String?,
                                 mainline : Int32?, allow_empty : Bool,
                                 max_object_bytes : Int32, max_index_bytes : Int32,
                                 max_total_bytes : Int64, max_entries : Int32,
-                                check : Proc(Nil)?, commit_result : Bool = true) : Sequencer::Result
+                                check : Proc(Nil)?, commit_result : Bool = true, config : Config? = nil,
+                                prepare_worktree : Proc(Array(Index::Entry), Merge::FilePlan, Int64)? = nil) : Sequencer::Result
       require_worktree!
+      config ||= self.config
       raise ArgumentError.new("invalid Git sequencer budgets") if max_object_bytes < 128 || max_index_bytes < 128 ||
                                                                   max_total_bytes < max_object_bytes || max_entries < 1 ||
                                                                   max_entries > @max_search_entries
       check!
       raise Error.new("Git sequencer unsupported with linked worktrees") unless @git_dir == @common &&
                                                                                 (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
       branch, old_oid = head_ref_and_oid
       unless old_oid && (branch.nil? || branch.starts_with?("refs/heads/"))
         raise Error.new("Git sequencer requires an existing branch or detached HEAD")
       end
       raise Error.new("Git sequencer refuses in-progress merge") if merge_state?
       raise Error.new("Git sequencer operation already in progress") if sequencer_state?
@@ -45,94 +47,101 @@ module Git
                        {} of String => Checkout::FileState
                      end
       base, theirs = kind.revert? ? {source_files, parent_files} : {parent_files, source_files}
       names = (ours.keys + theirs.keys + base.keys).uniq.sort
       raise Error.new("Git sequencer entry budget exceeded") if names.size > max_entries
       Checkout.require_tree_paths!(ours.keys, "Git sequencer HEAD tree")
       Checkout.require_tree_paths!(theirs.keys, "Git sequencer incoming tree")
       Checkout.require_tree_paths!(base.keys, "Git sequencer base tree")
       incoming_label = "#{kind.revert? ? "parent of " : ""}#{target[0, default_abbrev]} (#{source.message.lines.first? || ""})"
       rename_plan = Merge.rename_plan(self, base, ours, theirs,
         max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes, check: check,
         their_label: incoming_label)
+      snapshot = @index.snapshot_checksum(max_index_bytes)
       current = @index.entries(max_index_bytes) { check.try &.call }
       raise Error.new("Git sequencer requires index equal to HEAD") unless Merge.index_matches_head?(current, ours)
-      Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
-        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
+      conversion = Conversion.new(self, config: config, max_bytes: max_object_bytes,
+        max_index_bytes: max_index_bytes, check: check)
+      observations = Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
+        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true, conversion: conversion)
       marker_label = kind.revert? ? "parent of #{source_expression}" : source_expression
       plan = Merge.plan_files(self, names, base, ours, theirs, rename_plan,
         marker_label: marker_label, operation: "Git sequencer",
         max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes, check: check)
       plan = Merge.relocate_directories(self, plan, current, ours, theirs,
         their_label: incoming_label, max_object_bytes: max_object_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
-      edits, writes, conflicts = {plan.edits, plan.writes, plan.conflicts}
+      remaining = prepare_worktree.try(&.call(current, plan)) || max_total_bytes
+      raise Error.new("Git sequencer prepared byte budget invalid") unless 0 <= remaining <= max_total_bytes
+      output = Conversion.for_index(self, current, edits: plan.edits, writes: plan.writes,
+        config: config, max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
+      edits, conflicts = {plan.edits, plan.conflicts}
+      writes = output.materialize(plan.writes, max_total_bytes: remaining, operation: "Git sequencer")
       final_paths = plan.final_paths(current)
       raise Error.new("Git sequencer divergent file/directory conflict unsupported") if Checkout.path_collision(final_paths)
       Checkout.require_transition_destinations!(@root, ours.keys, final_paths,
         max_entries: max_entries)
       image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
         max_entries: max_entries * 3, check: check)
       blocking_removals, trailing_removals = plan.partition_removals
       transition_dirs = Checkout.transition_directories(ours.keys, final_paths)
       plan.validate_symlinks!
       recovery_data = Merge::Recovery.encode(plan.relocations, writes, old_oid, target,
         @object_format, max_index_bytes, max_entries)
       state = Sequencer::State.new(kind, branch, old_oid, target, parent,
         operation_author, text, allow_empty)
-      snapshot = @index.snapshot_checksum(max_index_bytes)
       admin = DescriptorPath::Directory.open(@git_dir)
       lock = nil.as(IO::FileDescriptor?)
       started = false
       index_published = false
       changed_paths = [] of String
       begin
         lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
         guard = -> do
           check.try &.call
           if started && Merge::Recovery.read(admin, "CRYSTAL_SEQUENCER_PATHS", max_index_bytes) != recovery_data
             raise Error.new("Git sequencer recovery metadata changed")
           end
           raise Error.new("Git sequencer HEAD changed") unless head_ref_and_oid == {branch, old_oid}
           raise Error.new("Git sequencer index changed") unless @index.snapshot_checksum(max_index_bytes) == snapshot
           raise Error.new("Git sequencer state changed") if started && sequencer_state? != state
         end
         guard.call
         Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
-          max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
+          max_total_bytes: max_total_bytes, check: check, allow_symlinks: true, conversion: conversion)
         Checkout.require_transition_destinations!(@root, ours.keys, final_paths,
           max_entries: max_entries)
         started = true
         sequencer_write_metadata!(admin, state, recovery_data)
         guard.call
         if planned = image
           raise Error.new("Git sequencer index image diverged") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
           lock.write(planned.data.to_slice)
           lock.flush
           lock.fsync
         end
         blocking_removals.each do |path, previous|
-          Checkout.remove(@root, path, previous, format: @object_format, check: guard)
+          Checkout.remove(@root, path, observations[path], format: @object_format, check: guard)
           changed_paths << path
         end
         transition_dirs.each do |directory|
           Checkout.remove_empty_directory(@root, directory, check: guard)
         end
         writes.each_with_index do |write, sequence|
-          Checkout.write(@root, write, sequence, expected_old: ours[write.path]?,
+          Checkout.write(@root, write, sequence, expected_old: observations[write.path]?,
             format: @object_format, check: guard)
           changed_paths << write.path
         end
         trailing_removals.each do |path, previous|
-          Checkout.remove(@root, path, previous, format: @object_format, check: guard)
+          Checkout.remove(@root, path, observations[path], format: @object_format, check: guard)
           changed_paths << path
         end
         if image
           guard.call
           raise Error.new("Git sequencer admin directory replaced") unless admin.attached_at?(@git_dir)
           admin.rename("index.lock", "index")
           index_published = true
           admin.sync
         end
       rescue ex
         raise Sequencer::PartialPublication.new(changed_paths.dup, index_published, ex) if started
         raise ex
