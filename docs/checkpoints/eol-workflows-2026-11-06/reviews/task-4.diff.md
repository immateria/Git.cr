Repository: /workspace/work/git-eol-workflows/stash
Base: d9e2b57459c379200952f6808aea321773ab3179
Head: 1ffd545bcbdafd7c10e04e4d7459225dbcd7671b

## Commits

1ffd545 Add native EOL conversion to stash workflows

## Stat

 spec/eol_stash_apply_spec.cr       | 248 ++++++++++++++++++++++++++
 spec/eol_stash_spec.cr             | 354 +++++++++++++++++++++++++++++++++++++
 src/git/workflow/stash.cr          |  15 +-
 src/git/workflow/stash/apply.cr    |  35 +++-
 src/git/workflow/stash/save.cr     |  67 +++++--
 src/git/workflow/stash/worktree.cr |  29 +--
 6 files changed, 709 insertions(+), 39 deletions(-)

## Diff

diff --git a/spec/eol_stash_apply_spec.cr b/spec/eol_stash_apply_spec.cr
new file mode 100644
index 0000000..12e4e69
--- /dev/null
+++ b/spec/eol_stash_apply_spec.cr
@@ -0,0 +1,248 @@
+require "./eol_stash_spec"
+
+describe "native stash text/EOL apply and pop" do
+  ["sha1", "sha256"].each do |format|
+    it "applies canonical #{format} mixed state with CRLF outputs and exact saved index restoration" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.write(File.join(root, "file.txt"), "staged\r\n")
+        GitOracle.run(root, "add", "file.txt")
+        staged = GitOracle.run(root, "rev-parse", ":file.txt").stdout.strip
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        File.write(File.join(root, "new.txt"), "untracked\r\n")
+        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
+        GitOracle.run(root, "stash", "apply", "-q", "--index")
+        expected_work = File.read(File.join(root, "file.txt"))
+        expected_untracked = File.read(File.join(root, "new.txt"))
+        expected_status = GitOracle.run(root, "status", "--porcelain=v1").stdout
+        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
+        File.delete(File.join(root, "new.txt"))
+        result = repo.stash.apply(actor: EolStashFixture.actor, restore_index: true)
+        result.conflicts.should be_empty
+        result.index_restored.should be_true
+        File.read(File.join(root, "file.txt")).should eq(expected_work)
+        File.read(File.join(root, "new.txt")).should eq(expected_untracked)
+        GitOracle.run(root, "rev-parse", ":file.txt").stdout.strip.should eq(staged)
+        GitOracle.run(root, "status", "--porcelain=v1").stdout.should eq(expected_status)
+      end
+    end
+
+    it "keeps third-parent #{format} attributes out of tracked replay and applies them to untracked restore" do
+      GitOracle.with_repo(format: format) do |root|
+        File.write(File.join(root, "file.txt"), "base\n")
+        GitOracle.run(root, "add", ".")
+        GitOracle.run(root, "commit", "-qm", "base")
+        repo = Git::Repository.new(root)
+        File.write(File.join(root, "file.txt"), "working\n")
+        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
+        File.write(File.join(root, "new.txt"), "untracked\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
+        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("working\n")
+        repo.stash.pop(actor: EolStashFixture.actor).dropped.should be_true
+        File.read(File.join(root, "file.txt")).should eq("working\n")
+        File.read(File.join(root, "new.txt")).should eq("untracked\r\n")
+        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::CRLF)
+        repo.refs.resolve?("refs/stash").should be_nil
+      end
+    end
+
+    it "uses planned tracked #{format} attributes for both replay and supplemental restore" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, EolStashFixture::LF)
+        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        File.write(File.join(root, "new.txt"), "untracked\r\n")
+        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
+        repo.stash.apply(actor: EolStashFixture.actor).conflicts.should be_empty
+        File.read(File.join(root, "file.txt")).should eq("working\r\n")
+        File.read(File.join(root, "new.txt")).should eq("untracked\r\n")
+        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::CRLF)
+      end
+    end
+
+    it "propagates explicit and default #{format} conversion config through apply and pop" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, "")
+        File.write(File.join(root, "file.txt"), "working\n")
+        File.write(File.join(root, "new.txt"), "untracked\n")
+        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
+        GitOracle.run(root, "config", "core.autocrlf", "true")
+        explicit = repo.config(command_values: [{"core.autocrlf", "false"}])
+        repo.stash.apply(actor: EolStashFixture.actor, config: explicit).conflicts.should be_empty
+        File.read(File.join(root, "file.txt")).should eq("working\n")
+        File.read(File.join(root, "new.txt")).should eq("untracked\n")
+        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
+        File.delete(File.join(root, "new.txt"))
+        repo.stash.pop(actor: EolStashFixture.actor).dropped.should be_true
+        File.read(File.join(root, "file.txt")).should eq("working\r\n")
+        File.read(File.join(root, "new.txt")).should eq("untracked\r\n")
+      end
+    end
+
+    it "retains canonical #{format} conflict stages and smudges conflict markers without dropping the stash" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.write(File.join(root, "file.txt"), "stashed\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor).not_nil!
+        File.write(File.join(root, "file.txt"), "current\r\n")
+        GitOracle.run(root, "add", "file.txt")
+        GitOracle.run(root, "commit", "-qm", "current")
+        result = repo.stash.pop(actor: EolStashFixture.actor)
+        result.dropped.should be_false
+        result.applied.conflicts.should eq(["file.txt"])
+        data = File.read(File.join(root, "file.txt"))
+        data.should contain("<<<<<<< HEAD\r\n")
+        data.gsub("\r\n", "").should_not contain('\n')
+        EolStashFixture.blob(root, ":1:file.txt").should eq("base\n")
+        EolStashFixture.blob(root, ":2:file.txt").should eq("current\n")
+        EolStashFixture.blob(root, ":3:file.txt").should eq("stashed\n")
+        repo.refs.resolve?("refs/stash").should eq(entry.oid)
+      end
+    end
+
+    it "rejects expanded supplemental #{format} files before tracked publication" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        File.write(File.join(root, "new.txt"), "u\r\n" * 200)
+        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
+        before = File.read(File.join(root, ".git", "index"))
+        expect_raises(Git::Error, /conversion byte budget/) do
+          repo.stash.apply(actor: EolStashFixture.actor, max_object_bytes: 512,
+            max_total_bytes: 4096_i64)
+        end
+        File.read(File.join(root, "file.txt")).should eq("base\r\n")
+        File.exists?(File.join(root, "new.txt")).should be_false
+        File.read(File.join(root, ".git", "index")).should eq(before)
+        File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD")).should be_false
+        File.exists?(File.join(root, ".git", "CRYSTAL_SEQUENCER_PATHS")).should be_false
+        repo.refs.resolve?("refs/stash").should eq(entry.oid)
+      end
+    end
+
+    it "reserves expanded #{format} supplemental bytes before materializing tracked writes" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.write(File.join(root, "file.txt"), "x\r\n" * 100)
+        File.write(File.join(root, "new.txt"), "u\r\n" * 100)
+        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
+        before = File.read(File.join(root, ".git", "index"))
+        expect_raises(Git::Error, /total byte budget/) do
+          repo.stash.apply(actor: EolStashFixture.actor, max_object_bytes: 512,
+            max_total_bytes: 512_i64)
+        end
+        File.read(File.join(root, "file.txt")).should eq("base\r\n")
+        File.exists?(File.join(root, "new.txt")).should be_false
+        File.read(File.join(root, ".git", "index")).should eq(before)
+      end
+    end
+
+    it "keeps current #{format} attributes and all supplemental destinations on a third-parent collision" do
+      GitOracle.with_repo(format: format) do |root|
+        File.write(File.join(root, "file.txt"), "base\n")
+        GitOracle.run(root, "add", ".")
+        GitOracle.run(root, "commit", "-qm", "base")
+        repo = Git::Repository.new(root)
+        File.write(File.join(root, "file.txt"), "working\n")
+        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
+        File.write(File.join(root, "new.txt"), "untracked\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
+        File.write(File.join(root, ".gitattributes"), EolStashFixture::LF)
+        error = expect_raises(Git::Stash::PartialApply) do
+          repo.stash.pop(actor: EolStashFixture.actor)
+        end
+        error.stash_oid.should eq(entry.oid)
+        File.read(File.join(root, "file.txt")).should eq("working\n")
+        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::LF)
+        File.exists?(File.join(root, "new.txt")).should be_false
+        repo.refs.resolve?("refs/stash").should eq(entry.oid)
+      end
+    end
+
+    it "uses deleted planned #{format} attributes without falling back to pre-apply worktree rules" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.delete(File.join(root, ".gitattributes"))
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        File.write(File.join(root, "new.txt"), "untracked\r\n")
+        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
+        repo.stash.apply(actor: EolStashFixture.actor).conflicts.should be_empty
+        File.exists?(File.join(root, ".gitattributes")).should be_false
+        File.read(File.join(root, "file.txt")).should eq("working\n")
+        File.read(File.join(root, "new.txt")).should eq("untracked\n")
+      end
+    end
+
+    it "leaves unchanged #{format} canonical blobs untouched during attributes-only replay" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, EolStashFixture::LF)
+        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
+        repo.stash.push(actor: EolStashFixture.actor).should_not be_nil
+        result = repo.stash.apply(actor: EolStashFixture.actor)
+        result.changed_paths.should eq([".gitattributes"])
+        File.read(File.join(root, "file.txt")).should eq("base\n")
+      end
+    end
+
+    it "keeps raw #{format} binary and symlink values when replaying converted trees" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, "* text=auto eol=crlf\n")
+        binary = "binary\0\r\n"
+        File.write(File.join(root, "file.txt"), binary)
+        File.symlink("target\r\n", File.join(root, "link"))
+        repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).should_not be_nil
+        repo.stash.apply(actor: EolStashFixture.actor).conflicts.should be_empty
+        File.read(File.join(root, "file.txt")).should eq(binary)
+        File.readlink(File.join(root, "link")).should eq("target\r\n")
+      end
+    end
+
+    it "refuses raw #{format} EOL-only races during tracked apply publication" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        path = File.join(root, "file.txt")
+        File.write(path, "working\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor).not_nil!
+        changed = false
+        check = -> do
+          if !changed && File.exists?(File.join(root, ".git", "CHERRY_PICK_HEAD"))
+            changed = true
+            File.write(path, "base\n")
+          end
+          nil
+        end
+        error = expect_raises(Git::Stash::PartialApply) do
+          repo.stash.apply(actor: EolStashFixture.actor, check: check)
+        end
+        error.changed_paths.should be_empty
+        File.read(path).should eq("base\n")
+        repo.refs.resolve?("refs/stash").should eq(entry.oid)
+      end
+    end
+
+    it "preserves Git's blob-source BOM policy for third-parent #{format} attributes" do
+      GitOracle.with_repo(format: format) do |root|
+        File.write(File.join(root, "file.txt"), "base\n")
+        GitOracle.run(root, "add", ".")
+        GitOracle.run(root, "commit", "-qm", "base")
+        repo = Git::Repository.new(root)
+        attributes = "\uFEFF" + EolStashFixture::CRLF
+        File.write(File.join(root, ".gitattributes"), attributes)
+        File.write(File.join(root, "file.txt"), "working\n")
+        File.write(File.join(root, "new.txt"), "untracked\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
+        EolStashFixture.blob(root, "#{entry.untracked_oid}:new.txt").should eq("untracked\n")
+        GitOracle.run(root, "stash", "apply", "-q")
+        expected = File.read(File.join(root, "new.txt"))
+        expected.should eq("untracked\n")
+        File.delete(File.join(root, ".gitattributes"))
+        File.delete(File.join(root, "new.txt"))
+        GitOracle.run(root, "reset", "--hard", "-q", "HEAD")
+        repo.stash.apply(actor: EolStashFixture.actor).conflicts.should be_empty
+        File.read(File.join(root, "file.txt")).should eq("working\n")
+        File.read(File.join(root, "new.txt")).should eq(expected)
+        File.read(File.join(root, ".gitattributes")).should eq(attributes)
+      end
+    end
+  end
+end
diff --git a/spec/eol_stash_spec.cr b/spec/eol_stash_spec.cr
new file mode 100644
index 0000000..c3c6422
--- /dev/null
+++ b/spec/eol_stash_spec.cr
@@ -0,0 +1,354 @@
+require "spec"
+require "file_utils"
+require "../src/git"
+require "./support/git_oracle"
+
+module EolStashFixture
+  LF   = "*.txt text eol=lf\n"
+  CRLF = "*.txt text eol=crlf\n"
+
+  def self.actor : Git::Signature
+    Git::Signature.new("EOL Stash", "eol-stash@example.invalid", 1_700_000_000_i64, 0)
+  end
+
+  def self.base(root : String, attributes : String = CRLF, text : String = "base\n") : Git::Repository
+    File.write(File.join(root, ".gitattributes"), attributes)
+    File.write(File.join(root, "file.txt"), text)
+    GitOracle.run(root, "add", ".")
+    GitOracle.run(root, "commit", "-qm", "base")
+    Git::Repository.new(root)
+  end
+
+  def self.blob(root : String, expression : String) : String
+    GitOracle.run(root, "show", expression).stdout
+  end
+end
+
+describe "native stash text/EOL capture and cleanup" do
+  ["sha1", "sha256"].each do |format|
+    it "stores canonical #{format} tracked, index and untracked trees and smudges cleanup" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.write(File.join(root, "file.txt"), "staged\r\n")
+        GitOracle.run(root, "add", "file.txt")
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        File.write(File.join(root, "new.txt"), "untracked\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
+        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("working\n")
+        EolStashFixture.blob(root, "#{entry.index_oid}:file.txt").should eq("staged\n")
+        EolStashFixture.blob(root, "#{entry.untracked_oid}:new.txt").should eq("untracked\n")
+        {"#{entry.oid}:file.txt"          => "working\n",
+         "#{entry.index_oid}:file.txt"    => "staged\n",
+         "#{entry.untracked_oid}:new.txt" => "untracked\n"}.each do |expression, content|
+          GitOracle.run(root, "rev-parse", expression).stdout.strip.should eq(
+            Git::ObjectId.digest("blob", content, repo.object_format))
+        end
+        File.read(File.join(root, "file.txt")).should eq("base\r\n")
+        File.exists?(File.join(root, "new.txt")).should be_false
+      end
+    end
+
+    it "treats clean #{format} CRLF working bytes as a canonical no-op" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.write(File.join(root, "file.txt"), "base\r\n")
+        repo.stash.push(actor: EolStashFixture.actor).should be_nil
+        repo.refs.resolve?("refs/stash").should be_nil
+        File.read(File.join(root, "file.txt")).should eq("base\r\n")
+      end
+    end
+
+    it "preserves canonical #{format} index state and CRLF bytes for keep_index" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.write(File.join(root, "file.txt"), "staged\r\n")
+        GitOracle.run(root, "add", "file.txt")
+        index_before = File.read(File.join(root, ".git", "index"))
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        repo.stash.push(actor: EolStashFixture.actor, keep_index: true).should_not be_nil
+        File.read(File.join(root, "file.txt")).should eq("staged\r\n")
+        File.read(File.join(root, ".git", "index")).should eq(index_before)
+      end
+    end
+
+    it "merges canonical #{format} staged-only cleanup while preserving unstaged edits" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, text: "base\nkeep\n")
+        File.write(File.join(root, "file.txt"), "staged\r\nkeep\r\n")
+        GitOracle.run(root, "add", "file.txt")
+        File.write(File.join(root, "file.txt"), "staged\r\nkeep\r\nunstaged\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor, staged_only: true).not_nil!
+        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("staged\nkeep\n")
+        File.read(File.join(root, "file.txt")).should eq("base\r\nkeep\r\nunstaged\r\n")
+      end
+    end
+
+    it "uses original worktree attributes for selected #{format} default cleanup" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.write(File.join(root, ".gitattributes"), EolStashFixture::LF)
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        repo.stash.push(actor: EolStashFixture.actor, paths: [".gitattributes", "file.txt"]).should_not be_nil
+        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::CRLF)
+        File.read(File.join(root, "file.txt")).should eq("base\n")
+      end
+    end
+
+    it "uses selected index attributes and unselected working attributes for #{format} keep_index cleanup" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, EolStashFixture::LF)
+        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
+        File.write(File.join(root, "file.txt"), "staged\r\n")
+        GitOracle.run(root, "add", ".")
+        File.write(File.join(root, ".gitattributes"), "*.txt -text\n")
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        repo.stash.push(actor: EolStashFixture.actor, keep_index: true,
+          paths: [".gitattributes", "file.txt"]).should_not be_nil
+        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::CRLF)
+        File.read(File.join(root, "file.txt")).should eq("staged\r\n")
+        File.write(File.join(root, ".gitattributes"), EolStashFixture::LF)
+        File.write(File.join(root, "file.txt"), "again\r\n")
+        repo.stash.push(actor: EolStashFixture.actor, keep_index: true,
+          paths: ["file.txt"]).should_not be_nil
+        File.read(File.join(root, "file.txt")).should eq("staged\n")
+        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::LF)
+      end
+    end
+
+    it "uses current worktree attributes for #{format} capture and HEAD attributes for full cleanup" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, EolStashFixture::LF)
+        File.write(File.join(root, ".gitattributes"), EolStashFixture::CRLF)
+        GitOracle.run(root, "add", ".gitattributes")
+        File.write(File.join(root, ".gitattributes"), "*.txt -text\n")
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor).not_nil!
+        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("working\r\n")
+        File.read(File.join(root, "file.txt")).should eq("base\n")
+        File.read(File.join(root, ".gitattributes")).should eq(EolStashFixture::LF)
+      end
+    end
+
+    it "honors default and explicit #{format} config without rejecting unchanged safecrlf predecessors" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, "")
+        GitOracle.run(root, "config", "core.autocrlf", "true")
+        GitOracle.run(root, "config", "core.safecrlf", "true")
+        File.write(File.join(root, "new.txt"), "new\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
+        EolStashFixture.blob(root, "#{entry.untracked_oid}:new.txt").should eq("new\n")
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        explicit = repo.config(command_values: [{"core.autocrlf", "false"}])
+        entry = repo.stash.push(actor: EolStashFixture.actor, config: explicit).not_nil!
+        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq("working\r\n")
+      end
+    end
+
+    it "refuses unsafe changed and new #{format} captures before publishing refs" do
+      [false, true].each do |untracked|
+        GitOracle.with_repo(format: format) do |root|
+          repo = EolStashFixture.base(root, "")
+          GitOracle.run(root, "config", "core.autocrlf", "true")
+          GitOracle.run(root, "config", "core.safecrlf", "true")
+          path = File.join(root, untracked ? "new.txt" : "file.txt")
+          File.write(path, "working\n")
+          expect_raises(Git::Error, /LF would be replaced by CRLF/) do
+            repo.stash.push(actor: EolStashFixture.actor, include_untracked: untracked)
+          end
+          repo.refs.resolve?("refs/stash").should be_nil
+          File.read(path).should eq("working\n")
+          File.exists?(File.join(root, ".git", "index.lock")).should be_false
+        end
+      end
+    end
+
+    it "warns once per #{format} capture and treats warning callbacks as arbitrary code" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, "")
+        GitOracle.run(root, "config", "core.autocrlf", "true")
+        GitOracle.run(root, "config", "core.safecrlf", "warn")
+        path = File.join(root, "file.txt")
+        File.write(path, "working\n")
+        warnings = [] of String
+        callback = ->(message : String) { warnings << message; nil }
+        repo.stash.push(actor: EolStashFixture.actor, warning: callback).should_not be_nil
+        warnings.size.should eq(1)
+        File.write(path, "next\n")
+        changing = ->(_message : String) { File.write(path, "next\r\n"); nil }
+        previous = repo.refs.resolve?("refs/stash")
+        expect_raises(Git::Error, /worktree changed during save/) do
+          repo.stash.push(actor: EolStashFixture.actor, warning: changing)
+        end
+        repo.refs.resolve?("refs/stash").should eq(previous)
+        File.read(path).should eq("next\r\n")
+      end
+    end
+
+    it "rejects expanded #{format} cleanup before reference or worktree publication" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, text: "x\n" * 100)
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        before = File.read(File.join(root, ".git", "index"))
+        expect_raises(Git::Error, /conversion byte budget/) do
+          repo.stash.push(actor: EolStashFixture.actor, max_object_bytes: 256,
+            max_total_bytes: 2048_i64)
+        end
+        repo.refs.resolve?("refs/stash").should be_nil
+        File.read(File.join(root, "file.txt")).should eq("working\r\n")
+        File.read(File.join(root, ".git", "index")).should eq(before)
+      end
+    end
+
+    it "keeps raw #{format} binary and symlink content outside text conversion" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, "* text=auto eol=crlf\n")
+        binary = "binary\0\r\n"
+        File.write(File.join(root, "file.txt"), binary)
+        File.symlink("target\r\n", File.join(root, "link"))
+        entry = repo.stash.push(actor: EolStashFixture.actor, include_untracked: true).not_nil!
+        EolStashFixture.blob(root, "#{entry.oid}:file.txt").should eq(binary)
+        EolStashFixture.blob(root, "#{entry.untracked_oid}:link").should eq("target\r\n")
+      end
+    end
+
+    it "preserves raw #{format} working bytes when a cleanup callback changes only EOLs" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        path = File.join(root, "file.txt")
+        File.write(path, "working\r\n")
+        changed = false
+        check = -> do
+          if !changed && repo.refs.resolve?("refs/stash")
+            changed = true
+            File.write(path, "working\n")
+          end
+          nil
+        end
+        error = expect_raises(Git::Stash::PartialSave) do
+          repo.stash.push(actor: EolStashFixture.actor, check: check)
+        end
+        error.changed_paths.should be_empty
+        repo.refs.resolve?("refs/stash").should eq(error.stash_oid)
+        File.read(path).should eq("working\n")
+      end
+    end
+
+    it "fails #{format} warning callback errors before stash publication" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, "")
+        GitOracle.run(root, "config", "core.autocrlf", "true")
+        GitOracle.run(root, "config", "core.safecrlf", "warn")
+        File.write(File.join(root, "new.txt"), "working\n")
+        warning = ->(_message : String) { raise "warning cancelled"; nil }
+        expect_raises(Exception, "warning cancelled") do
+          repo.stash.push(actor: EolStashFixture.actor, include_untracked: true, warning: warning)
+        end
+        repo.refs.resolve?("refs/stash").should be_nil
+        File.read(File.join(root, "new.txt")).should eq("working\n")
+      end
+    end
+
+    it "enforces the aggregate expanded #{format} cleanup budget before publication" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, text: "x\n" * 64)
+        File.write(File.join(root, "file.txt"), "changed\n" * 15)
+        before = File.read(File.join(root, ".git", "index"))
+        expect_raises(Git::Error, /total byte budget/) do
+          repo.stash.push(actor: EolStashFixture.actor, max_object_bytes: 256,
+            max_total_bytes: 256_i64)
+        end
+        repo.refs.resolve?("refs/stash").should be_nil
+        File.read(File.join(root, "file.txt")).should eq("changed\n" * 15)
+        File.read(File.join(root, ".git", "index")).should eq(before)
+      end
+    end
+
+    it "keeps exact #{format} selected path scope with nested attributes" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, EolStashFixture::LF)
+        Dir.mkdir(File.join(root, "nested"))
+        File.write(File.join(root, "nested", ".gitattributes"), EolStashFixture::CRLF)
+        File.write(File.join(root, "nested", "literal[1].txt"), "base\n")
+        File.write(File.join(root, "nested", "literal1.txt"), "other\n")
+        GitOracle.run(root, "add", ".")
+        GitOracle.run(root, "commit", "-qm", "nested")
+        File.write(File.join(root, "nested", "literal[1].txt"), "changed\r\n")
+        File.write(File.join(root, "nested", "literal1.txt"), "untouched\r\n")
+        entry = repo.stash.push(actor: EolStashFixture.actor, paths: ["nested/literal[1].txt"]).not_nil!
+        EolStashFixture.blob(root, "#{entry.oid}:nested/literal[1].txt").should eq("changed\n")
+        EolStashFixture.blob(root, "#{entry.oid}:nested/literal1.txt").should eq("other\n")
+        File.read(File.join(root, "nested", "literal[1].txt")).should eq("base\r\n")
+        File.read(File.join(root, "nested", "literal1.txt")).should eq("untouched\r\n")
+      end
+    end
+
+    it "retains indexed #{format} attributes when unselected worktree attributes are missing" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        File.write(File.join(root, "file.txt"), "staged\r\n")
+        GitOracle.run(root, "add", "file.txt")
+        File.delete(File.join(root, ".gitattributes"))
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        repo.stash.push(actor: EolStashFixture.actor, keep_index: true,
+          paths: ["file.txt"]).should_not be_nil
+        File.read(File.join(root, "file.txt")).should eq("staged\r\n")
+        File.exists?(File.join(root, ".gitattributes")).should be_false
+      end
+    end
+
+    it "refuses #{format} warning callbacks that change the index before publishing a stale plan" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root, "")
+        GitOracle.run(root, "config", "core.autocrlf", "true")
+        GitOracle.run(root, "config", "core.safecrlf", "warn")
+        File.write(File.join(root, "file.txt"), "working\n")
+        staged = "new staged content\n"
+        warning = ->(_message : String) { repo.stage_blob("file.txt", staged); nil }
+        expect_raises(Git::Error, /index changed/) do
+          repo.stash.push(actor: EolStashFixture.actor, warning: warning)
+        end
+        EolStashFixture.blob(root, ":file.txt").should eq(staged)
+        File.read(File.join(root, "file.txt")).should eq("working\n")
+        repo.refs.resolve?("refs/stash").should be_nil
+        File.exists?(File.join(root, ".git", "index.lock")).should be_false
+      end
+    end
+
+    it "does not parse selected #{format} symlink attribute targets as attribute data" do
+      GitOracle.with_repo(format: format) do |root|
+        repo = EolStashFixture.base(root)
+        attributes = File.join(root, ".gitattributes")
+        File.delete(attributes)
+        File.symlink(EolStashFixture::CRLF, attributes)
+        File.write(File.join(root, "file.txt"), "staged\n")
+        GitOracle.run(root, "add", ".")
+        File.write(File.join(root, "file.txt"), "working\r\n")
+        repo.stash.push(actor: EolStashFixture.actor, keep_index: true,
+          paths: [".gitattributes", "file.txt"]).should_not be_nil
+        File.read(File.join(root, "file.txt")).should eq("staged\n")
+        File.readlink(attributes).should eq(EolStashFixture::CRLF)
+      end
+    end
+
+    it "admits only canonical-clean #{format} content excluded by a staged deletion and keeps raw guards" do
+      [false, true].each do |modified|
+        GitOracle.with_repo(format: format) do |root|
+          repo = EolStashFixture.base(root)
+          GitOracle.run(root, "rm", "--cached", "-q", "file.txt")
+          raw = modified ? "modified\r\n" : "base\r\n"
+          File.write(File.join(root, "file.txt"), raw)
+          if modified
+            expect_raises(Git::Error, /excluded by staged deletion/) do
+              repo.stash.push(actor: EolStashFixture.actor)
+            end
+            repo.refs.resolve?("refs/stash").should be_nil
+          else
+            repo.stash.push(actor: EolStashFixture.actor).should_not be_nil
+            EolStashFixture.blob(root, ":file.txt").should eq("base\n")
+          end
+          File.read(File.join(root, "file.txt")).should eq(raw)
+        end
+      end
+    end
+  end
+end
diff --git a/src/git/workflow/stash.cr b/src/git/workflow/stash.cr
index 0a1e9c7..a8ef125 100644
--- a/src/git/workflow/stash.cr
+++ b/src/git/workflow/stash.cr
@@ -11,33 +11,36 @@ require "./stash/reflog"
 module Git
   # The stash (`git stash`): saved worktree and index states, newest at
   # position 0. Obtained from Repository#stash.
   struct Stash
     def initialize(@repository : Repository)
     end
 
     # `git stash push`: save tracked changes (and with include_untracked or
     # include_ignored, those files too) and clean them from the worktree.
     # keep_index leaves the index as staged; staged_only stashes just the
     # staged changes; paths limits the stash to exact repository-relative
     # paths. Returns nil when there was nothing to save. The caller supplies
-    # the identity and time: no Git config, environment or clock is read.
-    def push(*, actor : Signature, message : String? = nil,
+    # the identity and time. Conversion uses the supplied config or repository
+    # local config; environment and clock are not read. warning receives each
+    # safecrlf warning once per captured path, before stash publication.
+    def push(*, actor : Signature, message : String? = nil, config : Config? = nil,
+             warning : Proc(String, Nil)? = nil,
              include_untracked : Bool = false, include_ignored : Bool = false,
              keep_index : Bool = false, staged_only : Bool = false,
              paths : Array(String)? = nil,
              max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
              max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
              max_log_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Entry?
-      @repository.stash_push(actor: actor, message: message,
+      @repository.stash_push(actor: actor, message: message, config: config, warning: warning,
         include_untracked: include_untracked, include_ignored: include_ignored,
         keep_index: keep_index, staged_only: staged_only, paths: paths,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries,
         max_log_bytes: max_log_bytes, check: check)
     end
 
     # `git stash list`, newest first, up to limit entries.
     def list(*, limit : Int32 = 100, max_log_bytes : Int32 = 8_388_608,
              max_object_bytes : Int32 = 8_388_608, max_entries : Int32 = 10_000,
              check : Proc(Nil)? = nil) : Array(Entry)
       @repository.stash_list(limit: limit, max_log_bytes: max_log_bytes,
@@ -46,40 +49,42 @@ module Git
 
     # The entry at position (`stash@{position}`).
     def show(position : Int32 = 0, *, max_log_bytes : Int32 = 8_388_608,
              max_object_bytes : Int32 = 8_388_608, max_entries : Int32 = 10_000,
              check : Proc(Nil)? = nil) : Entry
       @repository.stash_show(position, max_log_bytes: max_log_bytes,
         max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
     end
 
     # `git stash apply`: replay an entry onto the worktree (and, with
     # restore_index, the index), keeping the entry.
     def apply(position : Int32 = 0, *, actor : Signature, restore_index : Bool = false,
+              config : Config? = nil,
               max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
               max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
               max_log_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Applied
-      @repository.stash_apply(position, actor: actor, restore_index: restore_index,
+      @repository.stash_apply(position, actor: actor, restore_index: restore_index, config: config,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries,
         max_log_bytes: max_log_bytes, check: check)
     end
 
     # `git stash pop`: apply, then drop the entry unless the application
     # left conflicts.
     def pop(position : Int32 = 0, *, actor : Signature, restore_index : Bool = false,
+            config : Config? = nil,
             max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
             max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
             max_log_bytes : Int32 = 8_388_608, check : Proc(Nil)? = nil) : Popped
-      @repository.stash_pop(position, actor: actor, restore_index: restore_index,
+      @repository.stash_pop(position, actor: actor, restore_index: restore_index, config: config,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries,
         max_log_bytes: max_log_bytes, check: check)
     end
 
     # `git stash drop`. Returns the dropped entry.
     def drop(position : Int32 = 0, *, max_log_bytes : Int32 = 8_388_608,
              max_object_bytes : Int32 = 8_388_608, max_entries : Int32 = 10_000,
              check : Proc(Nil)? = nil) : Entry
       @repository.stash_drop(position, max_log_bytes: max_log_bytes,
         max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
     end
diff --git a/src/git/workflow/stash/apply.cr b/src/git/workflow/stash/apply.cr
index d46ede1..05bab1c 100644
--- a/src/git/workflow/stash/apply.cr
+++ b/src/git/workflow/stash/apply.cr
@@ -1,46 +1,64 @@
 module Git
   class Repository
     # Apply a stash's base->worktree delta to a clean current HEAD without
     # creating a commit. Conflicts use Git index stages 1/2/3 and worktree
     # markers but leave the stash entry intact and no sequencer metadata.
     # restore_index reproduces the saved index exactly and is intentionally
     # restricted to the original base commit in this first native slice.
     protected def stash_apply(position : Int32 = 0, *, actor : Signature,
-                              restore_index : Bool = false,
+                              restore_index : Bool = false, config : Config? = nil,
                               max_object_bytes : Int32 = 8_388_608,
                               max_index_bytes : Int32 = 8_388_608,
                               max_total_bytes : Int64 = 67_108_864,
                               max_entries : Int32 = 10_000,
                               max_log_bytes : Int32 = 8_388_608,
                               check : Proc(Nil)? = nil) : Stash::Applied
+      config ||= self.config
       entry = stash_show(position, max_log_bytes: max_log_bytes,
         max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
-      untracked_writes, untracked_bytes = stash_untracked_writes(entry.untracked_oid,
+      untracked_canonical, _untracked_bytes = stash_untracked_writes(entry.untracked_oid,
         max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
-      tracked_budget = max_total_bytes - untracked_bytes
-      raise Error.new("Git stash total byte budget exceeded") if tracked_budget < max_object_bytes
+      untracked_writes = [] of Checkout::Write
+      # The sequencer invokes this after its complete canonical plan, before
+      # any publication. Third-parent attributes belong only to this later
+      # untracked phase; they never influence tracked replay output.
+      prepare_worktree = ->(current : Array(Index::Entry), plan : Merge::FilePlan) do
+        if untracked_canonical.empty?
+          max_total_bytes
+        else
+          conversion = Conversion.for_index(self, current,
+            edits: plan.edits, writes: plan.writes + untracked_canonical,
+            config: config, max_bytes: max_object_bytes,
+            max_index_bytes: max_index_bytes, check: check)
+          untracked_writes = conversion.materialize(untracked_canonical,
+            max_total_bytes: max_total_bytes, operation: "Git stash untracked restore")
+          reserved = untracked_writes.sum(0_i64) { |write| write.data.bytesize.to_i64 }
+          max_total_bytes - reserved
+        end
+      end
       if restore_index
         current_head = head_ref_and_oid[1]
         raise Error.new("Git stash --index requires original base HEAD") unless current_head == entry.base_oid
       end
       expected_head = head_ref_and_oid
       result = nil.as(Sequencer::Result?)
       begin
         result = sequencer_start(Sequencer::Kind::CherryPick, entry.oid,
           committer: actor, author: nil, message: nil, mainline: 1,
           allow_empty: true, max_object_bytes: max_object_bytes,
-          max_index_bytes: max_index_bytes, max_total_bytes: tracked_budget,
-          max_entries: max_entries, check: check, commit_result: false)
+          max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
+          max_entries: max_entries, check: check, commit_result: false,
+          config: config, prepare_worktree: prepare_worktree)
       rescue ex : Sequencer::PartialPublication
         raise Stash::PartialApply.new(entry.oid, ex.changed_paths, [] of String,
           false, ex)
       end
       applied = result.not_nil!
       changed_paths = applied.changed_paths.dup
       restored = false
       if applied.conflicts.empty?
         begin
           if restore_index
             read_tree(entry.index_oid, max_object_bytes: max_object_bytes,
               max_index_bytes: max_index_bytes, max_entries: max_entries, check: check)
@@ -77,32 +95,33 @@ module Git
           end
         rescue ex
           raise Stash::PartialApply.new(entry.oid, changed_paths,
             applied.conflicts, restored, ex)
         end
       end
       Stash::Applied.new(entry, changed_paths, applied.conflicts, restored)
     end
 
     # Apply and remove only after a conflict-free application. A conflict is
     # a successful stopped state: the stash remains on the stack for recovery.
     protected def stash_pop(position : Int32 = 0, *, actor : Signature,
-                            restore_index : Bool = false,
+                            restore_index : Bool = false, config : Config? = nil,
                             max_object_bytes : Int32 = 8_388_608,
                             max_index_bytes : Int32 = 8_388_608,
                             max_total_bytes : Int64 = 67_108_864,
                             max_entries : Int32 = 10_000,
                             max_log_bytes : Int32 = 8_388_608,
                             check : Proc(Nil)? = nil) : Stash::Popped
-      applied = stash_apply(position, actor: actor, restore_index: restore_index,
+      config ||= self.config
+      applied = stash_apply(position, actor: actor, restore_index: restore_index, config: config,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries,
         max_log_bytes: max_log_bytes, check: check)
       return Stash::Popped.new(applied, false) unless applied.conflicts.empty?
       begin
         stash_drop(position, max_log_bytes: max_log_bytes,
           max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
       rescue ex
         raise Stash::PartialPop.new(applied, ex)
       end
       Stash::Popped.new(applied, true)
     end
diff --git a/src/git/workflow/stash/save.cr b/src/git/workflow/stash/save.cr
index 4a6ea37..0ba9c44 100644
--- a/src/git/workflow/stash/save.cr
+++ b/src/git/workflow/stash/save.cr
@@ -1,39 +1,41 @@
 module Git
   class Repository
     # Save the index/worktree state and push it onto refs/stash. The default
     # tracked-only form uses Git's standard two-parent stash shape. With
     # include_untracked, a parentless third commit stores non-ignored untracked
     # files exactly as Git stash -u does. include_ignored widens that third
     # snapshot to all untracked leaves like Git stash -a and implies untracked
     # capture. keep_index preserves the caller's staged index. staged_only
     # stores only the index delta and removes that staged delta from the
     # worktree while preserving bounded non-overlapping unstaged edits. paths
     # selects exact repository-relative file paths without Git pathspec/glob
     # expansion; the stash object still retains Git's full saved-index parent.
-    # The caller supplies identity/time explicitly; no ambient Git config,
-    # environment or clock is consulted.
+    # The caller supplies identity/time explicitly. Conversion uses the supplied
+    # config or repository-local config; environment and clock are not read.
     protected def stash_push(*, actor : Signature, message : String? = nil,
+                             config : Config? = nil, warning : Proc(String, Nil)? = nil,
                              include_untracked : Bool = false,
                              include_ignored : Bool = false,
                              keep_index : Bool = false,
                              staged_only : Bool = false,
                              paths : Array(String)? = nil,
                              max_object_bytes : Int32 = 8_388_608,
                              max_index_bytes : Int32 = 8_388_608,
                              max_total_bytes : Int64 = 67_108_864,
                              max_entries : Int32 = 10_000,
                              max_log_bytes : Int32 = 8_388_608,
                              check : Proc(Nil)? = nil) : Stash::Entry?
       require_worktree!
+      config ||= self.config
       raise ArgumentError.new("invalid Git stash budgets") if max_object_bytes < 128 || max_index_bytes < 128 ||
                                                               max_total_bytes < max_object_bytes || max_entries < 1 ||
                                                               max_entries > @max_search_entries || max_log_bytes < 128
       selected_paths = if selected = paths
                          raise Error.new("empty Git stash selected paths") if selected.empty? || selected.size > max_entries
                          chosen = Set(String).new
                          selected.each do |path|
                            PathBytes.validate_relative!(path, max_depth: Metadata::MAX_DEPTH)
                            raise Error.new("Git stash selected path targets repository metadata") if path == ".git" || path.starts_with?(".git/")
                            raise Error.new("duplicate Git stash selected path") unless chosen.add?(path)
                          end
                          chosen
@@ -49,102 +51,114 @@ module Git
       raise Error.new("Git stash refuses in-progress sequencer operation") if sequencer_state?
       raise Error.new("Git stash refuses in-progress rebase") if rebase_state?
       if text = message
         raise Error.new("Git stash message invalid") if text.empty? || text.includes?('\0') || text.includes?('\n') || text.includes?('\r') || text.bytesize > 4096
       end
 
       branch, head_oid = head_ref_and_oid
       raise Error.new("Git stash requires an existing symbolic branch") unless branch && branch.starts_with?("refs/heads/") && head_oid
       head_commit = read_commit(head_oid, max_bytes: max_object_bytes, check: check)
       head_files = Checkout.tree_files(self, head_commit.tree,
         max_object_bytes: max_object_bytes, max_files: max_entries,
         check: check, allow_symlinks: true)
+      # Bind planning to the original index before callbacks can stage content.
+      checksum = @index.snapshot_checksum(max_index_bytes)
       current = @index.entries(max_index_bytes) { check.try &.call }
       raise Error.new("Git stash index entry budget exceeded") if current.size > max_entries
       current.each do |entry|
         raise Error.new("Git stash requires an ordinary resolved index") unless entry.stage == 0 && !entry.intent &&
                                                                                 !entry.skip_worktree && !entry.assume_unchanged &&
                                                                                 {"100644", "100755", "120000"}.includes?(entry.mode)
       end
       Checkout.require_tree_paths!(current.map(&.path), "Git stash index")
       index_tree = write_index_tree(max_index_bytes: max_index_bytes,
         max_tree_bytes: max_object_bytes, check: check)
       index_files = {} of String => Checkout::FileState
       current.each do |entry|
         index_files[entry.path] = Checkout::FileState.new(entry.mode, entry.oid)
       end
 
+      conversion = Conversion.new(self, config: config, max_bytes: max_object_bytes,
+        max_index_bytes: max_index_bytes, warning: warning, check: check)
+
       # Git partial stash stores a complete index-shaped worktree tree and
       # overlays only the selected paths with their actual worktree state.
       # This intentionally means unselected staged changes remain represented
       # in the stash object even though cleanup is limited to selected paths.
       worktree_files = selected_paths ? index_files.dup : ({} of String => Checkout::FileState)
       observed = {} of String => Checkout::FileState
       index_paths = current.map(&.path).to_set
       transferred = 0_i64
       current.each do |entry|
         next if selected_paths && !selected_paths.includes?(entry.path)
         check.try &.call
         if leaf = stash_worktree_leaf?(entry.path, max_object_bytes,
              allow_directory_missing: false, check: check)
           state, raw = leaf
           transferred += raw.bytesize
           raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
-          written = write_blob(raw, max_bytes: max_object_bytes.to_i64, check: check)
-          raise Error.new("Git stash worktree blob identity changed") unless written == state.oid
-          worktree_files[entry.path] = state
+          canonical = state.mode == "120000" ? raw : conversion.clean(entry.path, raw, index_oid: entry.oid)
+          oid = ObjectId.digest("blob", canonical, @object_format)
+          if state.mode != "120000" && oid != entry.oid
+            conversion.clean(entry.path, raw, index_oid: entry.oid, safe: true)
+          end
+          written = write_blob(canonical, max_bytes: max_object_bytes.to_i64, check: check)
+          raise Error.new("Git stash worktree blob identity changed") unless written == oid
+          worktree_files[entry.path] = Checkout::FileState.new(state.mode, oid)
           observed[entry.path] = state
         elsif selected_paths
           worktree_files.delete(entry.path)
         end
       end
 
       untracked_files = {} of String => Checkout::FileState
       capture_untracked = include_untracked || include_ignored
       if capture_untracked
         untracked_files, untracked_bytes = stash_untracked_files(index_paths,
           selected_paths: selected_paths,
-          include_ignored: include_ignored,
+          include_ignored: include_ignored, conversion: conversion, observed: observed,
           max_object_bytes: max_object_bytes,
           max_total_bytes: max_total_bytes - transferred,
           max_entries: max_entries,
           check: check)
         transferred += untracked_bytes
         untracked_files.each do |path, state|
-          observed[path] = state
           # A staged deletion makes a formerly tracked HEAD path untracked.
           # Git's -u stash records that leaf in both the worktree snapshot and
           # the third-parent untracked snapshot, so applying it later may
           # legitimately encounter the same collision Git does.
           worktree_files[path] = state if head_files.has_key?(path)
         end
       end
 
       # A path removed from the index is untracked from Git's point of view.
       # If it still occupies a HEAD path and was not captured by -u, preserve
-      # safety by accepting it only when it is byte-for-byte the original HEAD
-      # value. Git itself may overwrite a modified such path during cleanup;
+      # safety by accepting it only when its canonical content matches HEAD.
+      # Exact raw observations still authorize any cleanup overwrite. Git itself
+      # may overwrite a modified such path during cleanup;
       # this native lane intentionally refuses that data-loss case unless the
       # bytes are durably represented in the third-parent snapshot.
       head_files.each do |path, expected|
         next if selected_paths && !selected_paths.includes?(path)
         next if index_paths.includes?(path)
         next if untracked_files.has_key?(path)
         leaf = stash_worktree_leaf?(path, max_object_bytes,
           allow_directory_missing: true, check: check)
         next unless leaf
         actual, raw = leaf
         transferred += raw.bytesize
         raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
-        raise Error.new("Git stash refuses modified worktree content excluded by staged deletion") unless actual == expected
+        canonical = actual.mode == "120000" ? raw : conversion.clean(path, raw, index_oid: expected.oid)
+        canonical_state = Checkout::FileState.new(actual.mode, ObjectId.digest("blob", canonical, @object_format))
+        raise Error.new("Git stash refuses modified worktree content excluded by staged deletion") unless canonical_state == expected
         observed[path] = actual
       end
 
       if selected_paths
         selected_paths.each do |path|
           next if index_paths.includes?(path) || untracked_files.has_key?(path)
           raise Error.new("Git stash selected path did not match an indexed or captured worktree file: #{path}")
         end
       end
 
       worktree_tree = staged_only ? index_tree : stash_write_tree(worktree_files,
         max_object_bytes: max_object_bytes, check: check)
@@ -164,67 +178,90 @@ module Git
       image = if keep_index
                 nil
               else
                 desired_index = IndexRestore.source_entries(self, head_commit.tree,
                   max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
                 index_selection = selected_paths.try do |selected|
                   selected.select { |path| index_paths.includes?(path) || head_files.has_key?(path) }.to_set
                 end
                 edits = IndexRestore.edits(current, desired_index, index_selection)
                 edits.empty? ? nil : @index.prepare_changes(edits,
                   max_bytes: max_index_bytes, max_entries: max_entries, check: check)
               end
-      checksum = @index.snapshot_checksum(max_index_bytes)
       cleanup_files = if staged_only
-                        staged_cleanup, merged_bytes = stash_staged_cleanup_files(head_files, index_files, observed,
+                        staged_cleanup, merged_bytes = stash_staged_cleanup_files(head_files, index_files, worktree_files,
                           max_object_bytes: max_object_bytes,
                           max_total_bytes: max_total_bytes - transferred,
                           check: check)
                         transferred += merged_bytes
                         staged_cleanup
                       elsif selected_paths
                         source = keep_index ? index_files : head_files
                         selected_cleanup = {} of String => Checkout::FileState
                         selected_paths.each do |path|
                           if state = source[path]?
                             selected_cleanup[path] = state
                           end
                         end
                         selected_cleanup
                       elsif keep_index
                         index_files
                       else
                         head_files
                       end
 
       Checkout.require_tree_paths!(observed.keys, "Git stash worktree")
       Checkout.require_tree_paths!(cleanup_files.keys, "Git stash cleanup destination")
       Checkout.require_transition_destinations!(@root, observed.keys, cleanup_files.keys,
         max_entries: max_entries)
+      # Cleanup keeps canonical goals separate from the raw identities which
+      # authorize overwrites. Attribute timing follows the chosen stash form.
+      cleanup_conversion = if staged_only || (selected_paths && !keep_index)
+                             conversion
+                           elsif selected = selected_paths
+                             blobs = {} of String => String?
+                             selected.each do |path|
+                               next unless File.basename(path) == ".gitattributes"
+                               state = index_files[path]?
+                               blobs[path] = state && {"100644", "100755"}.includes?(state.mode) ? state.oid : nil
+                             end
+                             Conversion.new(self, config: config, attribute_blobs: blobs,
+                               worktree_fallback: true, worktree_index_fallback: true,
+                               max_bytes: max_object_bytes,
+                               max_index_bytes: max_index_bytes, check: check)
+                           else
+                             Conversion.new(self, config: config,
+                               attribute_tree: keep_index ? index_tree : head_commit.tree,
+                               max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
+                           end
       changed = (observed.keys + cleanup_files.keys).uniq.sort.select { |path| observed[path]? != cleanup_files[path]? }
       raise Error.new("Git stash cleanup entry budget exceeded") if changed.size > max_entries
       writes = [] of Checkout::Write
       removals = [] of String
       changed.each do |path|
         check.try &.call
         if goal = cleanup_files[path]?
           kind, raw = object(goal.oid, max_object_bytes) { check.try &.call }
           raise Error.new("Git stash cleanup target is not a blob") unless kind == "blob"
-          transferred += raw.bytesize
-          raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
           writes << Checkout::Write.new(path, goal.mode, goal.oid, raw)
         elsif observed.has_key?(path)
           removals << path
         end
       end
+      writes = cleanup_conversion.materialize(writes,
+        max_total_bytes: max_total_bytes - transferred, operation: "Git stash cleanup")
+      writes.reject! do |write|
+        raw = Checkout::FileState.new(write.mode, ObjectId.digest("blob", write.data, @object_format))
+        observed[write.path]? == raw
+      end
       write_paths = writes.map(&.path)
       blocking_removals, trailing_removals = removals.partition do |path|
         write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
       end
       transition_dirs = Checkout.transition_directories(observed.keys, cleanup_files.keys)
 
       # Validate the existing stack before appending another Git-compatible
       # reflog entry. Malformed or mismatched external state is never extended.
       stash_log_records(max_log_bytes: max_log_bytes, max_entries: max_entries,
         max_object_bytes: max_object_bytes, check: check)
       previous_stash = resolve_ref?(Stash::REF)
       branch_name = branch.byte_slice("refs/heads/".bytesize, branch.bytesize - "refs/heads/".bytesize)
@@ -257,25 +294,25 @@ module Git
       admin = DescriptorPath::Directory.open(@git_dir)
       index_lock = nil.as(IO::FileDescriptor?)
       started = false
       ref_published = false
       index_published = false
       changed_paths = [] of String
       begin
         # Serialize cooperative index writers before publishing refs/stash so a
         # pre-existing foreign lock cannot turn an otherwise avoidable refusal
         # into a saved-but-not-cleaned partial operation.
         index_lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
         guard.call
-        stash_verify_worktree_snapshot!(current, worktree_files, observed,
+        stash_verify_worktree_snapshot!(current, observed,
           selected_paths: selected_paths,
           max_object_bytes: max_object_bytes, check: check)
         Checkout.require_transition_destinations!(@root, observed.keys, cleanup_files.keys,
           max_entries: max_entries)
         if planned = image
           raise Error.new("Git stash cleanup index image diverged") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
           index_lock.write(planned.data.to_slice)
           index_lock.flush
           index_lock.fsync
         end
 
         update_ref(Stash::REF, stash_oid, expected_oid: previous_stash,
diff --git a/src/git/workflow/stash/worktree.cr b/src/git/workflow/stash/worktree.cr
index ec25619..0a6ea80 100644
--- a/src/git/workflow/stash/worktree.cr
+++ b/src/git/workflow/stash/worktree.cr
@@ -31,50 +31,55 @@ module Git
     end
 
     # Collect leaves that are untracked by the current index. By default the
     # native ignore rules exclude ignored leaves; include_ignored bypasses that
     # filter and descends ignored directories for stash -a parity. The traversal
     # never follows symlinked directories and every leaf
     # is re-read later before publication by stash_verify_worktree_snapshot!.
     # Blobs are written before the stash commit so its third-parent tree never
     # references an object that has not already been durably materialized.
     private def stash_untracked_files(index_paths : Set(String), *,
                                       selected_paths : Set(String)?,
                                       include_ignored : Bool,
+                                      conversion : Conversion,
+                                      observed : Hash(String, Checkout::FileState),
                                       max_object_bytes : Int32,
                                       max_total_bytes : Int64,
                                       max_entries : Int32,
                                       check : Proc(Nil)?) : {Hash(String, Checkout::FileState), Int64}
       raise Error.new("Git stash total byte budget exceeded") if max_total_bytes < 0
       ignore = include_ignored ? nil : Ignore.new(@root, @common, {max_object_bytes, @max_scan_bytes}.min)
       found = {} of String => Checkout::FileState
       transferred = 0_i64
       if selected_paths
         selected_paths.to_a.sort.each do |relative|
           check.try &.call
           next if index_paths.includes?(relative)
           full = File.join(@root, relative)
           is_directory = !File.symlink?(full) && Dir.exists?(full)
           next if is_directory
           next if ignore && ignore.ignored?(relative, false)
           leaf = stash_worktree_leaf?(relative, max_object_bytes,
             allow_directory_missing: true, check: check)
           next unless leaf
           raise Error.new("Git stash untracked capture entry budget exceeded") if found.size >= max_entries
           state, raw = leaf
           transferred += raw.bytesize
           raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
-          written = write_blob(raw, max_bytes: max_object_bytes.to_i64, check: check)
-          raise Error.new("Git stash untracked blob identity changed") unless written == state.oid
-          found[relative] = state
+          canonical = state.mode == "120000" ? raw : conversion.clean(relative, raw, safe: true)
+          oid = ObjectId.digest("blob", canonical, @object_format)
+          written = write_blob(canonical, max_bytes: max_object_bytes.to_i64, check: check)
+          raise Error.new("Git stash untracked blob identity changed") unless written == oid
+          found[relative] = Checkout::FileState.new(state.mode, oid)
+          observed[relative] = state
         end
         return {found, transferred}
       end
       queue = [{"", 0}]
       visited = 0
       until queue.empty?
         prefix, depth = queue.pop
         check.try &.call
         raise Error.new("Git stash untracked depth exceeded") if depth > Metadata::MAX_DEPTH
         location = prefix.empty? ? @root : File.join(@root, prefix)
         raise Error.new("Git stash untracked directory redirected") if File.symlink?(location) ||
                                                                        !Dir.exists?(location) ||
@@ -92,27 +97,30 @@ module Git
           if is_directory
             queue << {relative, depth + 1}
             next
           end
           next if index_paths.includes?(relative)
           raise Error.new("Git stash untracked capture entry budget exceeded") if found.size >= max_entries
           leaf = stash_worktree_leaf?(relative, max_object_bytes,
             allow_directory_missing: false, check: check) ||
                  raise Error.new("Git stash untracked leaf disappeared")
           state, raw = leaf
           transferred += raw.bytesize
           raise Error.new("Git stash total byte budget exceeded") if transferred > max_total_bytes
-          written = write_blob(raw, max_bytes: max_object_bytes.to_i64, check: check)
-          raise Error.new("Git stash untracked blob identity changed") unless written == state.oid
-          found[relative] = state
+          canonical = state.mode == "120000" ? raw : conversion.clean(relative, raw, safe: true)
+          oid = ObjectId.digest("blob", canonical, @object_format)
+          written = write_blob(canonical, max_bytes: max_object_bytes.to_i64, check: check)
+          raise Error.new("Git stash untracked blob identity changed") unless written == oid
+          found[relative] = Checkout::FileState.new(state.mode, oid)
+          observed[relative] = state
         end
       end
       {found, transferred}
     end
 
     # Materialize the third-parent tree into bounded checkout writes before any
     # worktree mutation. This validates the Git stash shape and object modes up
     # front; destination collision checks still occur after the tracked replay,
     # matching Git's ordering without ever overwriting an existing untracked
     # path.
     private def stash_untracked_writes(untracked_oid : String?, *,
                                        max_object_bytes : Int32,
@@ -140,35 +148,35 @@ module Git
       {writes, transferred}
     end
 
     # Compute the post-save worktree for --staged by applying the inverse
     # staged delta. The index is the merge base, the current worktree is ours,
     # and HEAD is theirs. Ordinary exact add/delete/modify cases resolve by
     # identity; bounded non-overlapping regular-file edits reuse the native
     # three-way text merge. Unsupported overlap fails before refs/stash is
     # published rather than leaving a Git-compatible but partially cleaned
     # staged-only save.
     private def stash_staged_cleanup_files(head_files : Hash(String, Checkout::FileState),
                                            index_files : Hash(String, Checkout::FileState),
-                                           observed : Hash(String, Checkout::FileState), *,
+                                           worktree_files : Hash(String, Checkout::FileState), *,
                                            max_object_bytes : Int32,
                                            max_total_bytes : Int64,
                                            check : Proc(Nil)?) : {Hash(String, Checkout::FileState), Int64}
       cleanup = {} of String => Checkout::FileState
       transferred = 0_i64
-      names = (head_files.keys + index_files.keys + observed.keys).uniq.sort
+      names = (head_files.keys + index_files.keys + worktree_files.keys).uniq.sort
       names.each do |path|
         check.try &.call
         base = index_files[path]?
-        ours = observed[path]?
+        ours = worktree_files[path]?
         theirs = head_files[path]?
         desired = if ours == theirs || theirs == base
                     ours
                   elsif ours == base
                     theirs
                   else
                     nil
                   end
         divergent = ours != theirs && ours != base && theirs != base
         if divergent
           if resolved = Merge.merge_blob(self, base, ours, theirs, max_object_bytes, check)
             desired = resolved[0]
@@ -203,36 +211,35 @@ module Git
       end
       return nil unless File.exists?(absolute)
       if Dir.exists?(absolute)
         return nil if allow_directory_missing
         raise Error.new("Git stash tracked worktree path became a directory")
       end
       raise Error.new("Git stash worktree leaf is unsupported") unless File.file?(absolute)
       mode, raw = checkout_working_regular(path, max_bytes) { check.try &.call }
       {Checkout::FileState.new(mode, ObjectId.digest("blob", raw, @object_format)), raw}
     end
 
     private def stash_verify_worktree_snapshot!(index : Array(Index::Entry),
-                                                expected : Hash(String, Checkout::FileState),
                                                 observed : Hash(String, Checkout::FileState), *,
                                                 selected_paths : Set(String)?,
                                                 max_object_bytes : Int32,
                                                 check : Proc(Nil)?) : Nil
       indexed = index.map(&.path).to_set
       index.each do |entry|
         next if selected_paths && !selected_paths.includes?(entry.path)
         leaf = stash_worktree_leaf?(entry.path, max_object_bytes,
           allow_directory_missing: false, check: check)
         actual = leaf.try(&.[0])
-        raise Error.new("Git stash worktree changed during save") unless actual == expected[entry.path]?
+        raise Error.new("Git stash worktree changed during save") unless actual == observed[entry.path]?
       end
       observed.each do |path, expected_state|
         next if indexed.includes?(path)
         leaf = stash_worktree_leaf?(path, max_object_bytes,
           allow_directory_missing: false, check: check)
         raise Error.new("Git stash excluded worktree path changed during save") unless leaf.try(&.[0]) == expected_state
       end
     end
 
     private def stash_write_tree(states : Hash(String, Checkout::FileState), *,
                                  max_object_bytes : Int32,
                                  check : Proc(Nil)?) : String
