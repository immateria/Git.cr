Repository: /workspace/work/git-eol-workflows/merge
Base: 8d6309702ea47693f837d4be44fc090f43d49f78
Head: 5804533b7b81f81e8a336558aac087fb0ee7c29a

## Commits

5804533 Cover merge recovery boundaries and pull conversion configuration
a3d271c Implement merge and fast-forward EOL conversion workflow integration

## Stat

 spec/eol_merge_spec.cr              | 461 ++++++++++++++++++++++++++++++++++++
 src/git/merge.cr                    |   4 +-
 src/git/merge/fast_forward.cr       |   9 +-
 src/git/merge/three_way/abort.cr    |  15 +-
 src/git/merge/three_way/initiate.cr |  31 ++-
 src/git/remote/pull.cr              |   9 +-
 6 files changed, 502 insertions(+), 27 deletions(-)

## Diff

diff --git a/spec/eol_merge_spec.cr b/spec/eol_merge_spec.cr
new file mode 100644
index 0000000..4bb5f2b
--- /dev/null
+++ b/spec/eol_merge_spec.cr
@@ -0,0 +1,461 @@
+require "spec"
+require "../src/git"
+require "./support/git_oracle"
+
+module EolMergeFixture
+  SIGNATURE = Git::Signature.new("EOL Merge", "eol-merge@example.invalid", 1_700_000_000_i64, 0)
+  LF        = "*.txt text eol=lf\n"
+  CRLF      = "*.txt text eol=crlf\n"
+
+  def self.commit(repository : Git::Repository, files : Hash(String, String), parents : Array(String) = [] of String,
+                  *, symlinks : Hash(String, String) = {} of String => String) : String
+    GitOracle.run(repository.root, "read-tree", "--empty")
+    files.each { |path, data| GitOracle.stage_blob(repository.root, path, data) }
+    symlinks.each do |path, target|
+      oid = GitOracle.stage_blob(repository.root, path, target)
+      GitOracle.run(repository.root, "update-index", "--cacheinfo", "120000", oid, path)
+    end
+    tree = GitOracle.run(repository.root, "write-tree").stdout.strip
+    repository.write_commit(tree: tree, parents: parents, author: SIGNATURE, committer: SIGNATURE, message: "fixture\n")
+  end
+
+  def self.install(repository : Git::Repository, ours : String, theirs : String) : Nil
+    repository.refs.update("refs/heads/main", ours, expected_oid: nil)
+    repository.refs.update("refs/heads/topic", theirs, expected_oid: nil)
+    GitOracle.run(repository.root, "reset", "--hard", "-q", ours)
+  end
+
+  def self.divergent(root : String, ours_attributes : String? = CRLF, theirs_attributes : String? = CRLF,
+                     *, base_attributes : String? = ours_attributes, conflict : Bool = false,
+                     path : String = "file.txt", attribute_path : String = ".gitattributes") : {Git::Repository, String, String}
+    repository = Git::Repository.new(root)
+    base_files = {path => "one\ntwo\nthree\n"}
+    base_files[attribute_path] = base_attributes if base_attributes
+    base = commit(repository, base_files)
+    ours_files = {path => conflict ? "OURS\n" : "OURS\ntwo\nthree\n"}
+    ours_files[attribute_path] = ours_attributes if ours_attributes
+    ours = commit(repository, ours_files, [base])
+    theirs_files = {path => conflict ? "THEIRS\n" : "one\ntwo\nTHEIRS\n"}
+    theirs_files[attribute_path] = theirs_attributes if theirs_attributes
+    theirs = commit(repository, theirs_files, [base])
+    install(repository, ours, theirs)
+    {repository, ours, theirs}
+  end
+
+  def self.merge(repository : Git::Repository, *, config : Git::Config? = nil,
+                 max_object_bytes : Int32 = 8_388_608, max_total_bytes : Int64 = 67_108_864,
+                 check : Proc(Nil)? = nil) : Git::Merge::Result
+    repository.merge("topic", author: SIGNATURE, committer: SIGNATURE, message: "merge\n", config: config,
+      max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes, check: check)
+  end
+
+  def self.index(root : String) : String
+    GitOracle.run(root, "ls-files", "-s").stdout
+  end
+
+  def self.oracle(root : String, path : String) : {String, String}
+    GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false)
+    expected = {File.read(File.join(root, path)), index(root)}
+    GitOracle.run(root, "merge", "--abort")
+    expected
+  end
+end
+
+describe "native merge text/EOL conversion" do
+  ["sha1", "sha256"].each do |format|
+    [{EolMergeFixture::LF, EolMergeFixture::CRLF}, {EolMergeFixture::CRLF, EolMergeFixture::LF}].each do |attributes|
+      [false, true].each do |conflict|
+        it "matches Git's #{format} #{conflict ? "conflict" : "clean"} merge with changed result attributes #{attributes[1].strip}" do
+          GitOracle.with_repo(format: format) do |root|
+            repository, ours, theirs = EolMergeFixture.divergent(root, attributes[0], attributes[1], conflict: conflict)
+            expected, index = EolMergeFixture.oracle(root, "file.txt")
+            result = EolMergeFixture.merge(repository)
+            File.read(File.join(root, "file.txt")).should eq(expected)
+            EolMergeFixture.index(root).should eq(index)
+            if conflict
+              result.conflicts.should eq(["file.txt"])
+              repository.merge.abort
+              repository.head.oid.should eq(ours)
+              expected_original = attributes[0] == EolMergeFixture::CRLF ? "OURS\r\n" : "OURS\n"
+              File.read(File.join(root, "file.txt")).should eq(expected_original)
+            else
+              result.commit_oid.should_not be_nil
+              repository.read_head_file("file.txt").should eq("OURS\ntwo\nTHEIRS\n")
+              repository.read_commit(repository.head.oid.not_nil!).parents.should eq([ours, theirs])
+              repository.working_changes.should be_empty
+            end
+          end
+        end
+      end
+    end
+
+    it "uses conflicted #{format} attribute marker content as the result source" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, _, _ = EolMergeFixture.divergent(root, EolMergeFixture::LF, EolMergeFixture::CRLF,
+          base_attributes: "*.txt text\n", conflict: true)
+        expected, index = EolMergeFixture.oracle(root, "file.txt")
+        EolMergeFixture.merge(repository).conflicts.should eq([".gitattributes", "file.txt"])
+        File.read(File.join(root, "file.txt")).should eq(expected)
+        expected.should contain("\r\n")
+        EolMergeFixture.index(root).should eq(index)
+        repository.merge.abort
+      end
+    end
+
+    it "honors deleted and nested #{format} planned attributes" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, _, _ = EolMergeFixture.divergent(root, EolMergeFixture::CRLF, nil,
+          path: "nested/file.txt", attribute_path: "nested/.gitattributes")
+        expected, index = EolMergeFixture.oracle(root, "nested/file.txt")
+        EolMergeFixture.merge(repository)
+        File.read(File.join(root, "nested", "file.txt")).should eq(expected)
+        expected.should eq("OURS\ntwo\nTHEIRS\n")
+        File.exists?(File.join(root, "nested", ".gitattributes")).should be_false
+        EolMergeFixture.index(root).should eq(index)
+      end
+    end
+
+    it "stages a resolved #{format} conflict canonically before continuing" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, ours, theirs = EolMergeFixture.divergent(root, conflict: true)
+        EolMergeFixture.merge(repository)
+        File.write(File.join(root, "file.txt"), "resolved\r\n")
+        repository.stage_file("file.txt")
+        oid = repository.merge.continue(author: EolMergeFixture::SIGNATURE, committer: EolMergeFixture::SIGNATURE)
+        repository.read_commit(oid).parents.should eq([ours, theirs])
+        repository.read_head_file("file.txt").should eq("resolved\n")
+        File.read(File.join(root, "file.txt")).should eq("resolved\r\n")
+        repository.merge.in_progress?.should be_false
+        repository.working_changes.should be_empty
+      end
+    end
+
+    ["node", "node~HEAD"].each do |matched|
+      it "converts #{format} relocated conflicts using the final #{matched} attribute rule" do
+        GitOracle.with_repo(format: format) do |root|
+          repository = Git::Repository.new(root)
+          attributes = "#{matched} text eol=crlf\n"
+          base = EolMergeFixture.commit(repository, {".gitattributes" => attributes})
+          ours = EolMergeFixture.commit(repository, {".gitattributes" => attributes, "node" => "ours\n"}, [base])
+          theirs = EolMergeFixture.commit(repository, {".gitattributes" => attributes, "node/child" => "theirs\n"}, [base])
+          EolMergeFixture.install(repository, ours, theirs)
+          expected, index = EolMergeFixture.oracle(root, "node~HEAD")
+          EolMergeFixture.merge(repository).conflicts.should eq(["node~HEAD"])
+          File.read(File.join(root, "node~HEAD")).should eq(expected)
+          EolMergeFixture.index(root).should eq(index)
+          repository.merge.abort
+          File.read(File.join(root, "node")).should eq(matched == "node" ? "ours\r\n" : "ours\n")
+          File.exists?(File.join(root, "node~HEAD")).should be_false
+        end
+      end
+    end
+  end
+end
+
+describe "native merge conversion guards and forwarding" do
+  ["sha1", "sha256"].each do |format|
+    ["fast_forward", "merge"].each do |operation|
+      it "forwards explicit #{format} config through #{operation}'s fast-forward path" do
+        GitOracle.with_repo(format: format) do |root|
+          repository = Git::Repository.new(root)
+          first = EolMergeFixture.commit(repository, {"file.txt" => "first\n"})
+          tip = EolMergeFixture.commit(repository, {"file.txt" => "second\n"}, [first])
+          EolMergeFixture.install(repository, first, tip)
+          config = repository.config(command_values: [{"core.autocrlf", "true"}] of {String, String?})
+          if operation == "fast_forward"
+            repository.fast_forward("topic", config: config).target_oid.should eq(tip)
+          else
+            EolMergeFixture.merge(repository, config: config).commit_oid.should eq(tip)
+          end
+          File.read(File.join(root, "file.txt")).should eq("second\r\n")
+          repository.read_head_file("file.txt").should eq("second\n")
+          repository.working_changes(config: config).should be_empty
+          GitOracle.run(root, "-c", "core.autocrlf=true", "status", "--porcelain").stdout.should eq("")
+        end
+      end
+    end
+
+    [false, true].each do |diverged|
+      it "preserves unchanged #{format} file bytes across an attribute-only #{diverged ? "merge" : "fast-forward"}" do
+        GitOracle.with_repo(format: format) do |root|
+          repository = Git::Repository.new(root)
+          original = {"file.txt" => "same\n", ".gitattributes" => EolMergeFixture::CRLF}
+          base = EolMergeFixture.commit(repository, original)
+          ours = diverged ? EolMergeFixture.commit(repository, original.merge({"ours" => "ours\n"}), [base]) : base
+          theirs = EolMergeFixture.commit(repository, original.merge({".gitattributes" => EolMergeFixture::LF}), [base])
+          EolMergeFixture.install(repository, ours, theirs)
+          result = EolMergeFixture.merge(repository)
+          result.changed_paths.should_not contain("file.txt")
+          File.read(File.join(root, "file.txt")).should eq("same\r\n")
+          repository.read_head_file("file.txt").should eq("same\n")
+        end
+      end
+    end
+
+    it "uses explicit #{format} conversion config for merge and original-tree abort" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, ours, _ = EolMergeFixture.divergent(root, nil, nil, conflict: true)
+        config = repository.config(command_values: [{"core.autocrlf", "true"}] of {String, String?})
+        File.write(File.join(root, "file.txt"), "OURS\r\n")
+        EolMergeFixture.merge(repository, config: config).conflicts.should eq(["file.txt"])
+        File.read(File.join(root, "file.txt")).should eq("<<<<<<< HEAD\r\nOURS\r\n=======\r\nTHEIRS\r\n>>>>>>> topic\r\n")
+        repository.merge.abort(config: config)
+        File.read(File.join(root, "file.txt")).should eq("OURS\r\n")
+        repository.head.oid.should eq(ours)
+        repository.working_changes(config: config).should be_empty
+      end
+    end
+
+    it "refuses an EOL-only #{format} racing replacement using the original raw identity" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, ours, _ = EolMergeFixture.divergent(root)
+        before = File.read(File.join(root, ".git", "index"))
+        altered = false
+        check = -> do
+          if !altered && File.exists?(File.join(root, ".git", "MERGE_HEAD"))
+            File.write(File.join(root, "file.txt"), "OURS\ntwo\nthree\n")
+            altered = true
+          end
+          nil
+        end
+        error = expect_raises(Git::Merge::PartialPublication) { EolMergeFixture.merge(repository, check: check) }
+        altered.should be_true
+        error.changed_paths.should be_empty
+        error.index_published.should be_false
+        error.original_error.message.should match(/tracked file changed/)
+        repository.head.oid.should eq(ours)
+        File.read(File.join(root, ".git", "index")).should eq(before)
+        File.read(File.join(root, "file.txt")).should eq("OURS\ntwo\nthree\n")
+        repository.merge.abort
+      end
+    end
+
+    it "recovers unpublished #{format} relocated CRLF outputs only under their exact raw receipt" do
+      GitOracle.with_repo(format: format) do |root|
+        repository = Git::Repository.new(root)
+        attrs = "node~topic text eol=crlf\n"
+        base = EolMergeFixture.commit(repository, {".gitattributes" => attrs})
+        ours = EolMergeFixture.commit(repository, {".gitattributes" => attrs, "node/child" => "ours\n"}, [base])
+        theirs = EolMergeFixture.commit(repository, {".gitattributes" => attrs, "node" => "theirs\n"}, [base])
+        EolMergeFixture.install(repository, ours, theirs)
+        before = EolMergeFixture.index(root)
+        relocated = File.join(root, "node~topic")
+        check = -> do
+          raise Git::Error.new("injected after relocated publication") if File.exists?(relocated)
+        end
+        error = expect_raises(Git::Merge::PartialPublication) { EolMergeFixture.merge(repository, check: check) }
+        error.index_published.should be_false
+        File.read(relocated).should eq("theirs\r\n")
+        raw = File.read(File.join(root, ".git", "CRYSTAL_MERGE_PATHS"))
+        receipt = Git::Merge::Recovery.decode(raw, ours, theirs, repository.object_format, 8_388_608, 10_000)
+        receipt.outputs["node~topic"].oid.should eq(Git::ObjectId.digest("blob", "theirs\r\n", repository.object_format))
+        File.write(relocated, "theirs\n")
+        expect_raises(Git::Error, /untracked or changed unpublished output/) { repository.merge.abort }
+        File.read(relocated).should eq("theirs\n")
+        repository.merge.in_progress?.should be_true
+        File.write(relocated, "theirs\r\n")
+        repository.merge.abort
+        File.exists?(relocated).should be_false
+        File.read(File.join(root, "node", "child")).should eq("ours\n")
+        repository.head.oid.should eq(ours)
+        EolMergeFixture.index(root).should eq(before)
+      end
+    end
+  end
+
+  it "rejects per-file CRLF expansion before merge metadata or worktree publication" do
+    GitOracle.with_repo do |root|
+      repository = Git::Repository.new(root)
+      base_files = {"file.txt" => "base\n", ".gitattributes" => EolMergeFixture::CRLF}
+      base = EolMergeFixture.commit(repository, base_files)
+      ours = EolMergeFixture.commit(repository, base_files.merge({"ours" => "ours\n"}), [base])
+      theirs = EolMergeFixture.commit(repository, base_files.merge({"file.txt" => "a\n" * 180}), [base])
+      EolMergeFixture.install(repository, ours, theirs)
+      before = File.read(File.join(root, ".git", "index"))
+      orig_head_path = File.join(root, ".git", "ORIG_HEAD")
+      orig_head = File.exists?(orig_head_path) ? File.read(orig_head_path) : nil
+      expect_raises(Git::Error, /budget/) { EolMergeFixture.merge(repository, max_object_bytes: 384) }
+      repository.head.oid.should eq(ours)
+      File.read(File.join(root, "file.txt")).should eq("base\r\n")
+      File.read(File.join(root, ".git", "index")).should eq(before)
+      ["MERGE_HEAD", "MERGE_MSG", "CRYSTAL_MERGE_ORIG", "CRYSTAL_MERGE_PATHS", "index.lock"].each do |name|
+        File.exists?(File.join(root, ".git", name)).should be_false
+      end
+      (File.exists?(orig_head_path) ? File.read(orig_head_path) : nil).should eq(orig_head)
+    end
+  end
+
+  it "rejects aggregate CRLF expansion before merge metadata publication" do
+    GitOracle.with_repo do |root|
+      repository = Git::Repository.new(root)
+      original = {"a.txt" => "a\n", "b.txt" => "b\n", ".gitattributes" => EolMergeFixture::CRLF}
+      base = EolMergeFixture.commit(repository, original)
+      ours = EolMergeFixture.commit(repository, original.merge({"ours" => "ours\n"}), [base])
+      theirs = EolMergeFixture.commit(repository, original.merge({"a.txt" => "a\n" * 120, "b.txt" => "b\n" * 120}), [base])
+      EolMergeFixture.install(repository, ours, theirs)
+      before = File.read(File.join(root, ".git", "index"))
+      expect_raises(Git::Error, /budget/) { EolMergeFixture.merge(repository, max_object_bytes: 512, max_total_bytes: 600) }
+      repository.head.oid.should eq(ours)
+      File.read(File.join(root, ".git", "index")).should eq(before)
+      File.read(File.join(root, "a.txt")).should eq("a\r\n")
+      File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
+    end
+  end
+end
+
+describe "native merge conversion preservation" do
+  ["sha1", "sha256"].each do |format|
+    [{EolMergeFixture::LF, EolMergeFixture::CRLF}, {EolMergeFixture::CRLF, EolMergeFixture::LF}].each do |attributes|
+      it "fast-forwards clean #{format} predecessors using target #{attributes[1].strip} attributes" do
+        GitOracle.with_repo(format: format) do |root|
+          repository = Git::Repository.new(root)
+          first = EolMergeFixture.commit(repository, {"file.txt" => "first\n", ".gitattributes" => attributes[0]})
+          tip = EolMergeFixture.commit(repository, {"file.txt" => "second\n", ".gitattributes" => attributes[1]}, [first])
+          EolMergeFixture.install(repository, first, tip)
+          GitOracle.run(root, "merge", "--ff-only", "topic")
+          expected = File.read(File.join(root, "file.txt"))
+          index = EolMergeFixture.index(root)
+          GitOracle.run(root, "reset", "--hard", "-q", first)
+          repository.fast_forward("topic").target_oid.should eq(tip)
+          File.read(File.join(root, "file.txt")).should eq(expected)
+          EolMergeFixture.index(root).should eq(index)
+          repository.read_head_file("file.txt").should eq("second\n")
+        end
+      end
+    end
+
+    it "uses nested #{format} result attributes when root attributes select LF" do
+      GitOracle.with_repo(format: format) do |root|
+        repository = Git::Repository.new(root)
+        base_files = {".gitattributes" => EolMergeFixture::LF, "nested/file.txt" => "base\n"}
+        base = EolMergeFixture.commit(repository, base_files)
+        ours = EolMergeFixture.commit(repository, base_files.merge({"ours" => "ours\n"}), [base])
+        theirs = EolMergeFixture.commit(repository, base_files.merge({"nested/.gitattributes" => EolMergeFixture::CRLF, "nested/file.txt" => "theirs\n"}), [base])
+        EolMergeFixture.install(repository, ours, theirs)
+        expected, index = EolMergeFixture.oracle(root, "nested/file.txt")
+        EolMergeFixture.merge(repository)
+        File.read(File.join(root, "nested", "file.txt")).should eq(expected)
+        expected.should eq("theirs\r\n")
+        EolMergeFixture.index(root).should eq(index)
+      end
+    end
+
+    it "preserves #{format} binary payloads and raw symlink targets" do
+      GitOracle.with_repo(format: format) do |root|
+        repository = Git::Repository.new(root)
+        attrs = "*.txt text eol=crlf\n*.bin -text\nlink text eol=crlf\n"
+        base_files = {".gitattributes" => attrs, "file.txt" => "base\n", "raw.bin" => "base\0\n"}
+        base = EolMergeFixture.commit(repository, base_files, symlinks: {"link" => "before\n"})
+        ours = EolMergeFixture.commit(repository, base_files.merge({"ours" => "ours\n"}), [base], symlinks: {"link" => "before\n"})
+        payload = "changed\0\r\nraw\n"
+        theirs = EolMergeFixture.commit(repository, base_files.merge({"file.txt" => "theirs\n", "raw.bin" => payload}), [base], symlinks: {"link" => "after\n"})
+        EolMergeFixture.install(repository, ours, theirs)
+        EolMergeFixture.merge(repository)
+        File.read(File.join(root, "file.txt")).should eq("theirs\r\n")
+        File.read(File.join(root, "raw.bin")).should eq(payload)
+        File.readlink(File.join(root, "link")).should eq("after\n")
+        entry = repository.index_entries.find { |candidate| candidate.path == "raw.bin" }.not_nil!
+        repository.read_object(entry.oid).should eq(Git::RawObject.new(Git::ObjectType::Blob, payload))
+        GitOracle.run(root, "show", "HEAD:link").stdout.should eq("after\n")
+        repository.working_changes.should be_empty
+      end
+    end
+  end
+
+  [false, true].each do |diverged|
+    it "forwards selected conversion config through a #{diverged ? "diverged" : "fast-forward"} pull" do
+      GitOracle.with_repo do |root|
+        repository = Git::Repository.new(root)
+        first = EolMergeFixture.commit(repository, {"file.txt" => "first\n"})
+        tip = EolMergeFixture.commit(repository, {"file.txt" => "second\n"}, [first])
+        ours = diverged ? EolMergeFixture.commit(repository, {"file.txt" => "first\n", "ours" => "ours\n"}, [first]) : first
+        EolMergeFixture.install(repository, ours, tip)
+        remote = File.join(File.dirname(root), "remote.git")
+        GitOracle.run(root, "clone", "--bare", "-q", root, remote)
+        GitOracle.run(remote, "update-ref", "refs/heads/main", tip)
+        repository.remotes.add("origin", remote)
+        repository.branches.set_upstream("main", Git::Branch::Upstream.new("origin", "refs/heads/main"))
+        config = repository.config(command_values: [{"core.autocrlf", "true"}] of {String, String?})
+        result = repository.pull(mode: Git::Pull::Mode::Merge, author: EolMergeFixture::SIGNATURE, config: config)
+        result.action.should eq(diverged ? Git::Pull::Action::Merge : Git::Pull::Action::FastForward)
+        File.read(File.join(root, "file.txt")).should eq("second\r\n")
+        repository.read_head_file("file.txt").should eq("second\n")
+        repository.working_changes(config: config).should be_empty
+      end
+    end
+  end
+end
+
+describe "native merge conversion recovery boundaries" do
+  ["sha1", "sha256"].each do |format|
+    it "materializes original #{format} CRLF bytes even when abort sees the canonical original blob" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, ours, _ = EolMergeFixture.divergent(root, conflict: true)
+        EolMergeFixture.merge(repository)
+        File.write(File.join(root, "file.txt"), "OURS\n")
+        repository.merge.abort
+        File.read(File.join(root, "file.txt")).should eq("OURS\r\n")
+        repository.head.oid.should eq(ours)
+        repository.working_changes.should be_empty
+      end
+    end
+
+    it "refuses genuinely dirty #{format} CRLF content before starting a merge" do
+      GitOracle.with_repo(format: format) do |root|
+        repository, ours, _ = EolMergeFixture.divergent(root)
+        before = File.read(File.join(root, ".git", "index"))
+        File.write(File.join(root, "file.txt"), "dirty\r\n")
+        expect_raises(Git::Error, /dirty tracked files/) { EolMergeFixture.merge(repository) }
+        repository.head.oid.should eq(ours)
+        File.read(File.join(root, ".git", "index")).should eq(before)
+        File.read(File.join(root, "file.txt")).should eq("dirty\r\n")
+        repository.merge.in_progress?.should be_false
+      end
+    end
+  end
+
+  it "forwards explicit config through an initial pull checkout" do
+    GitOracle.with_repo do |root|
+      repository = Git::Repository.new(root)
+      tip = EolMergeFixture.commit(repository, {"file.txt" => "first\n"})
+      repository.refs.update("refs/heads/main", tip, expected_oid: nil)
+      destination = File.join(File.dirname(root), "initial-pull")
+      Dir.mkdir(destination)
+      pulled = Git::Repository.init(destination)
+      pulled.remotes.add("origin", root)
+      pulled.branches.set_upstream("main", Git::Branch::Upstream.new("origin", "refs/heads/main"))
+      config = pulled.config(command_values: [{"core.autocrlf", "true"}] of {String, String?})
+      pulled.pull(config: config).action.should eq(Git::Pull::Action::Initial)
+      File.read(File.join(destination, "file.txt")).should eq("first\r\n")
+      pulled.read_head_file("file.txt").should eq("first\n")
+      pulled.working_changes(config: config).should be_empty
+    end
+  end
+
+  it "retains a racing EOL-only replacement on the fast-forward publication path" do
+    GitOracle.with_repo do |root|
+      repository = Git::Repository.new(root)
+      original = {"file.txt" => "first\n", ".gitattributes" => EolMergeFixture::CRLF}
+      first = EolMergeFixture.commit(repository, original)
+      tip = EolMergeFixture.commit(repository, original.merge({"file.txt" => "second\n"}), [first])
+      EolMergeFixture.install(repository, first, tip)
+      before = File.read(File.join(root, ".git", "index"))
+      altered = false
+      check = -> do
+        if !altered && File.exists?(File.join(root, ".git", "index.lock"))
+          File.write(File.join(root, "file.txt"), "first\n")
+          altered = true
+        end
+        nil
+      end
+      error = expect_raises(Git::Reset::PartialPublication) { repository.fast_forward("topic", check: check) }
+      altered.should be_true
+      error.changed_worktree_paths.should be_empty
+      error.index_published.should be_false
+      error.reference_published.should be_false
+      repository.head.oid.should eq(first)
+      File.read(File.join(root, ".git", "index")).should eq(before)
+      File.read(File.join(root, "file.txt")).should eq("first\n")
+    end
+  end
+end
diff --git a/src/git/merge.cr b/src/git/merge.cr
index 49234a3..e358b25 100644
--- a/src/git/merge.cr
+++ b/src/git/merge.cr
@@ -23,27 +23,27 @@ module Git
 
     # `git merge --continue`: commit the resolved index with both parents.
     # Returns the merge commit's ID.
     def continue(*, author : Signature, committer : Signature, message : String? = nil,
                  max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
                  check : Proc(Nil)? = nil) : String
       @repository.merge_continue(author: author, committer: committer, message: message,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
     end
 
     # `git merge --abort`: restore the index and worktree to the branch's
     # commit. Returns the paths it changed.
-    def abort(*, max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
+    def abort(*, config : Config? = nil, max_object_bytes : Int32 = 8_388_608, max_index_bytes : Int32 = 8_388_608,
               max_total_bytes : Int64 = 67_108_864, max_entries : Int32 = 10_000,
               check : Proc(Nil)? = nil) : Array(String)
-      @repository.merge_abort(max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
+      @repository.merge_abort(config: config, max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
     end
   end
 
   class Repository
     # The merge in progress.
     def merge : Merge
       Merge.new(self)
     end
   end
 end
diff --git a/src/git/merge/fast_forward.cr b/src/git/merge/fast_forward.cr
index 709a770..c162969 100644
--- a/src/git/merge/fast_forward.cr
+++ b/src/git/merge/fast_forward.cr
@@ -2,54 +2,55 @@ module Git
   struct Merge
     record FastForwardResult, previous_oid : String, target_oid : String, changed_paths : Array(String)
   end
 
   class Repository
     # `git merge --ff-only <source>`: advance the current branch (or detached
     # HEAD) to a descendant commit, only if the tracked worktree is clean and
     # the index matches HEAD (unlike a hard reset, staged or unstaged edits are
     # refused). ORIG_HEAD records the previous commit. With actor, the branch
     # (when attached) and HEAD reflogs get Git's "merge <source>: Fast-forward".
     # It shares the hard reset's write path, partial-publication error and
     # filesystem limits. No merge commit or conflict handling.
-    def fast_forward(source : String, *,
+    def fast_forward(source : String, *, config : Config? = nil,
                      max_history_nodes : Int32 = 16_384,
                      max_object_bytes : Int32 = 8_388_608,
                      max_index_bytes : Int32 = 8_388_608,
                      max_total_bytes : Int64 = 67_108_864,
                      max_entries : Int32 = 10_000,
                      actor : Signature? = nil,
                      check : Proc(Nil)? = nil) : Merge::FastForwardResult
-      fast_forward_as("merge #{source}", source, max_history_nodes: max_history_nodes,
+      fast_forward_as("merge #{source}", source, config: config, max_history_nodes: max_history_nodes,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, actor: actor, check: check)
     end
 
     # fast_forward, logging as Git's reflog action (`merge <source>`, `pull`).
-    protected def fast_forward_as(action : String, source : String, *,
+    protected def fast_forward_as(action : String, source : String, *, config : Config? = nil,
                                   max_history_nodes : Int32 = 16_384,
                                   max_object_bytes : Int32 = 8_388_608,
                                   max_index_bytes : Int32 = 8_388_608,
                                   max_total_bytes : Int64 = 67_108_864,
                                   max_entries : Int32 = 10_000,
                                   actor : Signature? = nil,
                                   check : Proc(Nil)? = nil) : Merge::FastForwardResult
+      selected_config = config || self.config
       check!
       raise Error.new("Git fast-forward refuses in-progress merge") if merge_state?
       raise Error.new("Git fast-forward refuses in-progress sequencer operation") if sequencer_state?
       raise Error.new("Git fast-forward refuses in-progress rebase") if rebase_state?
       reference, old = head_ref_and_oid
       unless old && (reference.nil? || reference.starts_with?("refs/heads/"))
         raise Error.new("Git fast-forward requires an existing branch or detached HEAD")
       end
       target = History.resolve_commit(self, source, max_object_bytes, check)
       bases = merge_bases(old, target, max_nodes: max_history_nodes,
         max_commit_bytes: max_object_bytes, check: check)
       raise Error.new("Git merge is not a fast-forward") unless bases == [old]
       log = actor.try { |who| References::LogEntry.new(who, "#{action}: Fast-forward") }
-      result = reset_head_hard(source, log: log, max_object_bytes: max_object_bytes,
+      result = reset_head_hard(source, log: log, config: selected_config, max_object_bytes: max_object_bytes,
         max_index_bytes: max_index_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, clean_only: true, check: check)
       Merge::FastForwardResult.new(old, target, result.changed_worktree_paths)
     end
   end
 end
diff --git a/src/git/merge/three_way/abort.cr b/src/git/merge/three_way/abort.cr
index aab3e64..dfb916a 100644
--- a/src/git/merge/three_way/abort.cr
+++ b/src/git/merge/three_way/abort.cr
@@ -1,65 +1,70 @@
 module Git
   class Repository
     # Abort an incomplete native merge by restoring ordinary tracked content
     # and the entire index to the still-current original HEAD. This is an
     # explicitly destructive operation on merge-touched tracked paths.
-    protected def merge_abort(*, max_object_bytes : Int32 = 8_388_608,
+    protected def merge_abort(*, config : Config? = nil, max_object_bytes : Int32 = 8_388_608,
                               max_index_bytes : Int32 = 8_388_608,
                               max_total_bytes : Int64 = 67_108_864,
                               max_entries : Int32 = 10_000,
                               check : Proc(Nil)? = nil) : Array(String)
       require_worktree!
+      selected_config = config || self.config
       branch, ours_oid, theirs_oid = merge_state? || raise Error.new("no Git merge in progress")
       raise Error.new("Git merge abort HEAD changed") unless head_ref_and_oid == {branch, ours_oid}
       ours_tree = read_commit(ours_oid, max_bytes: max_object_bytes, check: check).tree
       theirs_tree = read_commit(theirs_oid, max_bytes: max_object_bytes, check: check).tree
       ours = Checkout.tree_files(self, ours_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
       theirs = Checkout.tree_files(self, theirs_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
       current = @index.entries(max_index_bytes) { check.try &.call }
       manifest_admin = DescriptorPath::Directory.open(@git_dir)
       begin
         relocation_data = Merge::Recovery.read(manifest_admin, "CRYSTAL_MERGE_PATHS", max_index_bytes)
       ensure
         manifest_admin.close
       end
       receipt = Merge::Recovery.decode(relocation_data, ours_oid, theirs_oid,
         @object_format, max_index_bytes, max_entries)
       allowed = (ours.keys + theirs.keys + receipt.paths + receipt.outputs.keys).uniq
       raise Error.new("Git merge abort refuses unrelated staged paths") if current.any? { |entry| !allowed.includes?(entry.path) }
       Checkout.require_tree_paths!(ours.keys, "Git merge abort target")
-      view = Merge::Recovery.observe(self, current, ours, receipt,
+      conversion = Conversion.new(self, config: selected_config, attribute_tree: ours_tree,
+        max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
+      raw_ours = conversion.raw_states(ours, max_total_bytes: max_total_bytes, operation: "Git merge abort")
+      view = Merge::Recovery.observe(self, current, raw_ours, receipt,
         max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes,
         max_entries: max_entries, check: check)
       view.preflight!(@root, ours.keys, max_entries)
       desired = IndexRestore.source_entries(self, ours_tree,
         max_object_bytes: max_object_bytes, max_entries: max_entries, check: check)
       edits = IndexRestore.edits(current, desired, nil)
       image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
         max_entries: max_entries * 3, check: check)
       snapshot = @index.snapshot_checksum(max_index_bytes)
       observations = view.observations
       writes = [] of Checkout::Write
       removals = [] of {String, Checkout::FileState}
       total = view.bytes
       observations.keys.sort.each do |path|
         check.try &.call
         observed = observations[path]
         if goal = ours[path]?
-          next if goal == observed
+          next if raw_ours[path] == observed
           kind, raw = object(goal.oid, max_object_bytes) { check.try &.call }
           raise Error.new("Git merge abort source not blob") unless kind == "blob"
-          total += raw.bytesize
+          data = goal.mode == "120000" ? raw : conversion.checkout(path, raw)
+          total += data.bytesize
           raise Error.new("Git merge abort total byte budget exceeded") if total > max_total_bytes
-          writes << Checkout::Write.new(path, goal.mode, goal.oid, raw)
+          writes << Checkout::Write.new(path, goal.mode, goal.oid, data)
         elsif observed_state = observed
           removals << {path, observed_state}
         end
       end
       write_paths = writes.map(&.path)
       blocking_removals, trailing_removals = removals.partition do |path, _state|
         write_paths.any? { |written| Checkout.transition_blocker?(path, written) }
       end
       transition_dirs = view.transition_directories(ours.keys)
       admin = DescriptorPath::Directory.open(@git_dir)
       lock = nil.as(IO::FileDescriptor?)
       started = false
diff --git a/src/git/merge/three_way/initiate.cr b/src/git/merge/three_way/initiate.cr
index 1f9852a..cf8e88b 100644
--- a/src/git/merge/three_way/initiate.cr
+++ b/src/git/merge/three_way/initiate.cr
@@ -1,66 +1,68 @@
 module Git
   class Repository
     # Bounded three-way tree merge with recursively combined common ancestors,
     # exact and edited-file renames, and file/directory conflict relocation.
     # A clean merge is committed with two parents. Conflicts retain real
     # index stages and MERGE_HEAD for explicit continuation or abort.
     def merge(source : String, *, author : Signature, committer : Signature,
+              config : Config? = nil,
               message : String, max_history_nodes : Int32 = 16_384,
               max_object_bytes : Int32 = 8_388_608,
               max_index_bytes : Int32 = 8_388_608,
               max_total_bytes : Int64 = 67_108_864,
               max_entries : Int32 = 10_000,
               check : Proc(Nil)? = nil) : Merge::Result
-      merge_as("merge #{source}", source, author: author, committer: committer,
+      merge_as("merge #{source}", source, author: author, committer: committer, config: config,
         message: message, max_history_nodes: max_history_nodes,
         max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
     end
 
     # merge, logging as Git's reflog action (`merge <source>`, `pull`).
-    protected def merge_as(action : String, source : String, *, author : Signature,
+    protected def merge_as(action : String, source : String, *, author : Signature, config : Config? = nil,
                            committer : Signature, message : String,
                            max_history_nodes : Int32 = 16_384,
                            max_object_bytes : Int32 = 8_388_608,
                            max_index_bytes : Int32 = 8_388_608,
                            max_total_bytes : Int64 = 67_108_864,
                            max_entries : Int32 = 10_000,
                            check : Proc(Nil)? = nil) : Merge::Result
       require_worktree!
+      selected_config = config || self.config
       raise ArgumentError.new("invalid Git three-way merge budgets") if max_history_nodes < 1 || max_object_bytes < 128 ||
                                                                         max_index_bytes < 128 || max_total_bytes < max_object_bytes ||
                                                                         max_entries < 1 || max_entries > @max_search_entries
       raise Error.new("Git merge message invalid") if message.empty? || message.includes?('\0') || message.bytesize > 65_536
       check!
       raise Error.new("Git three-way merge unsupported with linked worktrees") unless @git_dir == @common &&
                                                                                       (!Dir.exists?(File.join(@common, "worktrees")) || Dir.empty?(File.join(@common, "worktrees")))
       branch, old_oid = head_ref_and_oid
       unless old_oid && (branch.nil? || branch.starts_with?("refs/heads/"))
         raise Error.new("Git three-way merge requires an existing branch or detached HEAD")
       end
       raise Error.new("Git merge is already in progress") if merge_state?
       raise Error.new("Git merge refuses in-progress sequencer operation") if sequencer_state?
       raise Error.new("Git merge refuses in-progress rebase") if rebase_state?
       raise Error.new("Git merge state files already exist") if merge_metadata_exists?
       target = History.resolve_commit(self, source, max_object_bytes, check)
       bases = merge_bases(old_oid, target, max_nodes: max_history_nodes,
         max_commit_bytes: max_object_bytes, check: check)
       raise Error.new("Git three-way merge requires a common ancestor") if bases.empty?
       if target == old_oid || bases == [target]
         write_orig_head(old_oid)
         return Merge::Result.new(old_oid, target, bases[0], [] of String, [] of String, nil)
       end
       if bases == [old_oid]
-        fast = fast_forward_as(action, source, max_history_nodes: max_history_nodes,
+        fast = fast_forward_as(action, source, config: selected_config, max_history_nodes: max_history_nodes,
           max_object_bytes: max_object_bytes, max_index_bytes: max_index_bytes,
           max_total_bytes: max_total_bytes, max_entries: max_entries, actor: committer, check: check)
         return Merge::Result.new(old_oid, target, old_oid, fast.changed_paths, [] of String, target)
       end
       base_oid = if bases.size == 1
                    bases[0]
                  else
                    Merge::Bases.new(self, max_history_nodes, max_object_bytes,
                      max_total_bytes, max_entries, check).combine(old_oid, target)
                  end
       orig_tree = read_commit(old_oid, max_bytes: max_object_bytes, check: check).tree
       theirs_tree = read_commit(target, max_bytes: max_object_bytes, check: check).tree
@@ -68,33 +70,38 @@ module Git
       ours = Checkout.tree_files(self, orig_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
       theirs = Checkout.tree_files(self, theirs_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
       base = Checkout.tree_files(self, base_tree, max_object_bytes: max_object_bytes, max_files: max_entries, check: check, allow_symlinks: true)
       names = (ours.keys + theirs.keys + base.keys).uniq.sort
       raise Error.new("Git merge entry budget exceeded") if names.size > max_entries
       Checkout.require_tree_paths!(ours.keys, "Git ours tree")
       Checkout.require_tree_paths!(theirs.keys, "Git theirs tree")
       Checkout.require_tree_paths!(base.keys, "Git base tree")
       rename_plan = Merge.rename_plan(self, base, ours, theirs,
         max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes, check: check, their_label: source)
       current = @index.entries(max_index_bytes) { check.try &.call }
       raise Error.new("Git merge requires index equal to HEAD") unless Merge.index_matches_head?(current, ours)
-      Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
-        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
+      clean_conversion = Conversion.new(self, config: selected_config, max_bytes: max_object_bytes,
+        max_index_bytes: max_index_bytes, check: check)
+      observed = Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
+        max_total_bytes: max_total_bytes, check: check, allow_symlinks: true, conversion: clean_conversion)
       plan = Merge.plan_files(self, names, base, ours, theirs, rename_plan,
         marker_label: source, operation: "Git merge",
         max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes, check: check)
       plan = Merge.relocate_directories(self, plan, current, ours, theirs,
         their_label: source, max_object_bytes: max_object_bytes,
         max_total_bytes: max_total_bytes, max_entries: max_entries, check: check)
-      edits, writes, conflicts = {plan.edits, plan.writes, plan.conflicts}
+      output_conversion = Conversion.for_index(self, current, edits: plan.edits, writes: plan.writes,
+        config: selected_config, max_bytes: max_object_bytes, max_index_bytes: max_index_bytes, check: check)
+      writes = output_conversion.materialize(plan.writes, max_total_bytes: max_total_bytes, operation: "Git merge")
+      edits, conflicts = {plan.edits, plan.conflicts}
       final_paths = plan.final_paths(current)
       if Checkout.path_collision(final_paths)
         raise Error.new("Git merge divergent file/directory conflict unsupported")
       end
       Checkout.require_transition_destinations!(@root, ours.keys, final_paths,
         max_entries: max_entries)
       image = edits.empty? ? nil : @index.prepare_changes(edits, max_bytes: max_index_bytes,
         max_entries: max_entries * 3, check: check)
       blocking_removals, trailing_removals = plan.partition_removals
       transition_dirs = Checkout.transition_directories(ours.keys, final_paths)
       # Verify that symlink targets are publishable before any MERGE_HEAD or
       # worktree mutation is attempted, rather than leaving a stranded merge.
@@ -111,51 +118,51 @@ module Git
         lock = admin.open_file("index.lock", LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o666)
         guard = -> do
           check.try &.call
           if started && Merge::Recovery.read(admin, "CRYSTAL_MERGE_PATHS", max_index_bytes) != recovery_data
             raise Error.new("Git merge recovery metadata changed")
           end
           raise Error.new("Git merge HEAD changed") unless head_ref_and_oid == {branch, old_oid}
           raise Error.new("Git merge index changed") unless @index.snapshot_checksum(max_index_bytes) == snapshot
           raise Error.new("Git merge state changed") if started && merge_state? != {branch, old_oid, target}
         end
         guard.call
         Checkout.require_clean!(self, current, max_blob_bytes: max_object_bytes,
-          max_total_bytes: max_total_bytes, check: check, allow_symlinks: true)
+          max_total_bytes: max_total_bytes, check: check, allow_symlinks: true, conversion: clean_conversion)
         Checkout.require_transition_destinations!(@root, ours.keys, final_paths,
           max_entries: max_entries)
         started = true
         write_orig_head(old_oid)
         merge_write_metadata!(admin, branch, old_oid, target, message, recovery_data)
         guard.call
         if planned = image
           raise Error.new("Git merge index image diverged") unless @index.image_state(planned, max_bytes: max_index_bytes) == :before
           lock.write(planned.data.to_slice)
           lock.flush
           lock.fsync
         end
-        blocking_removals.each do |path, state|
-          Checkout.remove(@root, path, state, format: @object_format, check: guard)
+        blocking_removals.each do |path, _state|
+          Checkout.remove(@root, path, observed[path], format: @object_format, check: guard)
           changed_paths << path
         end
         transition_dirs.each do |directory|
           Checkout.remove_empty_directory(@root, directory, check: guard)
         end
         writes.each_with_index do |write, sequence|
-          Checkout.write(@root, write, sequence, expected_old: ours[write.path]?,
+          Checkout.write(@root, write, sequence, expected_old: observed[write.path]?,
             format: @object_format, check: guard)
           changed_paths << write.path
         end
-        trailing_removals.each do |path, state|
-          Checkout.remove(@root, path, state, format: @object_format, check: guard)
+        trailing_removals.each do |path, _state|
+          Checkout.remove(@root, path, observed[path], format: @object_format, check: guard)
           changed_paths << path
         end
         if image
           guard.call
           raise Error.new("Git merge admin directory replaced") unless admin.attached_at?(@git_dir)
           admin.rename("index.lock", "index")
           index_published = true
           admin.sync
         end
       rescue ex
         raise Merge::PartialPublication.new(changed_paths.dup, index_published, ex) if started
         raise ex
diff --git a/src/git/remote/pull.cr b/src/git/remote/pull.cr
index cb80825..2dc40be 100644
--- a/src/git/remote/pull.cr
+++ b/src/git/remote/pull.cr
@@ -18,52 +18,53 @@ module Git
       # A merge commit was made, or a conflicted merge was left to resolve.
       Merge
     end
 
     record Result, fetch : Fetch::Result, previous : String?, current : String?,
       action : Action, merge : Merge::Result? = nil
   end
 
   class Repository
     # `git pull`: fetch the current branch's upstream, then fast-forward or
     # merge it. Merges use the native three-way merge; a conflicted merge
     # stops with Git's merge state for merge_continue or merge_abort.
-    def pull(*, mode : Pull::Mode = Pull::Mode::FastForwardOnly, transport : Transport? = nil,
+    def pull(*, mode : Pull::Mode = Pull::Mode::FastForwardOnly, transport : Transport? = nil, config : Config? = nil,
              author : Signature? = nil, committer : Signature? = nil,
              actor : Signature? = nil, progress : Proc(String, Nil)? = nil,
              max_entries : Int32 = 100_000, max_total_bytes : Int64 = 1_073_741_824,
              check : Proc(Nil)? = nil) : Pull::Result
       require_worktree!
+      selected_config = config || self.config
       branch_ref = head_ref_and_oid[0] || raise Error.new("Git pull needs a checked-out branch")
       raise Error.new("Git pull needs a branch") unless branch_ref.starts_with?("refs/heads/")
       branch = branch_ref.byte_slice(11)
       remote_name, merge_ref = branch_upstream(branch) || raise Error.new("Git branch #{branch} has no upstream")
       fetched = fetch(remote_name, transport: transport, actor: actor, progress: progress, check: check)
       tracking = upstream_tracking_ref(remote_name, merge_ref) || raise Error.new("Git upstream #{merge_ref} is not fetched")
       target = resolve_ref?(tracking) || raise Error.new("Git upstream #{tracking} does not exist")
       previous = head_ref_and_oid[1]
       if previous.nil?
         update_ref(branch_ref, target, expected_oid: nil, max_object_bytes: 268_435_456)
-        populate_worktree(target, max_files: max_entries, check: check)
+        populate_worktree(target, config: selected_config, max_files: max_entries, check: check)
         return Pull::Result.new(fetched, nil, target, Pull::Action::Initial)
       end
       walker = History::RevisionWalker.new(self, check: check)
       if previous == target || walker.ancestor?(target, previous)
         write_orig_head(previous)
         return Pull::Result.new(fetched, previous, previous, Pull::Action::UpToDate)
       end
       if walker.ancestor?(previous, target)
-        fast_forward_as("pull", target, max_object_bytes: 268_435_456, max_index_bytes: Int32::MAX // 2,
+        fast_forward_as("pull", target, config: selected_config, max_object_bytes: 268_435_456, max_index_bytes: Int32::MAX // 2,
           max_total_bytes: max_total_bytes, max_entries: Math.min(max_entries, @max_search_entries),
           actor: actor, check: check)
         return Pull::Result.new(fetched, previous, target, Pull::Action::FastForward)
       end
       raise Error.new("Git pull cannot fast-forward #{branch}: histories diverged") if mode.fast_forward_only?
       who = author || raise Error.new("Git pull merge needs an author")
       message = "Merge branch '#{merge_ref.sub(/\Arefs\/heads\//, "")}' of #{remote(remote_name).url}\n"
-      result = merge_as("pull", target, author: who, committer: committer || who, message: message,
+      result = merge_as("pull", target, author: who, committer: committer || who, message: message, config: selected_config,
         max_object_bytes: 268_435_456, max_index_bytes: Int32::MAX // 2, max_total_bytes: max_total_bytes,
         max_entries: Math.min(max_entries, @max_search_entries), check: check)
       Pull::Result.new(fetched, previous, head_ref_and_oid[1], Pull::Action::Merge, result)
     end
   end
 end
