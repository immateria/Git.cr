require "spec"
require "../src/git"
require "./support/git_oracle"

module EolMergeFixture
  SIGNATURE = Git::Signature.new("EOL Merge", "eol-merge@example.invalid", 1_700_000_000_i64, 0)
  LF        = "*.txt text eol=lf\n"
  CRLF      = "*.txt text eol=crlf\n"

  def self.commit(repository : Git::Repository, files : Hash(String, String), parents : Array(String) = [] of String,
                  *, symlinks : Hash(String, String) = {} of String => String) : String
    GitOracle.run(repository.root, "read-tree", "--empty")
    files.each { |path, data| GitOracle.stage_blob(repository.root, path, data) }
    symlinks.each do |path, target|
      oid = GitOracle.stage_blob(repository.root, path, target)
      GitOracle.run(repository.root, "update-index", "--cacheinfo", "120000", oid, path)
    end
    tree = GitOracle.run(repository.root, "write-tree").stdout.strip
    repository.write_commit(tree: tree, parents: parents, author: SIGNATURE, committer: SIGNATURE, message: "fixture\n")
  end

  def self.install(repository : Git::Repository, ours : String, theirs : String) : Nil
    repository.refs.update("refs/heads/main", ours, expected_oid: nil)
    repository.refs.update("refs/heads/topic", theirs, expected_oid: nil)
    GitOracle.run(repository.root, "reset", "--hard", "-q", ours)
  end

  def self.divergent(root : String, ours_attributes : String? = CRLF, theirs_attributes : String? = CRLF,
                     *, base_attributes : String? = ours_attributes, conflict : Bool = false,
                     path : String = "file.txt", attribute_path : String = ".gitattributes") : {Git::Repository, String, String}
    repository = Git::Repository.new(root)
    base_files = {path => "one\ntwo\nthree\n"}
    base_files[attribute_path] = base_attributes if base_attributes
    base = commit(repository, base_files)
    ours_files = {path => conflict ? "OURS\n" : "OURS\ntwo\nthree\n"}
    ours_files[attribute_path] = ours_attributes if ours_attributes
    ours = commit(repository, ours_files, [base])
    theirs_files = {path => conflict ? "THEIRS\n" : "one\ntwo\nTHEIRS\n"}
    theirs_files[attribute_path] = theirs_attributes if theirs_attributes
    theirs = commit(repository, theirs_files, [base])
    install(repository, ours, theirs)
    {repository, ours, theirs}
  end

  def self.merge(repository : Git::Repository, *, config : Git::Config? = nil,
                 max_object_bytes : Int32 = 8_388_608, max_total_bytes : Int64 = 67_108_864,
                 check : Proc(Nil)? = nil) : Git::Merge::Result
    repository.merge("topic", author: SIGNATURE, committer: SIGNATURE, message: "merge\n", config: config,
      max_object_bytes: max_object_bytes, max_total_bytes: max_total_bytes, check: check)
  end

  def self.index(root : String) : String
    GitOracle.run(root, "ls-files", "-s").stdout
  end

  def self.oracle(root : String, path : String) : {String, String}
    GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false)
    expected = {File.read(File.join(root, path)), index(root)}
    GitOracle.run(root, "merge", "--abort")
    expected
  end
end

describe "native merge text/EOL conversion" do
  ["sha1", "sha256"].each do |format|
    [{EolMergeFixture::LF, EolMergeFixture::CRLF}, {EolMergeFixture::CRLF, EolMergeFixture::LF}].each do |attributes|
      [false, true].each do |conflict|
        it "matches Git's #{format} #{conflict ? "conflict" : "clean"} merge with changed result attributes #{attributes[1].strip}" do
          GitOracle.with_repo(format: format) do |root|
            repository, ours, theirs = EolMergeFixture.divergent(root, attributes[0], attributes[1], conflict: conflict)
            expected, index = EolMergeFixture.oracle(root, "file.txt")
            result = EolMergeFixture.merge(repository)
            File.read(File.join(root, "file.txt")).should eq(expected)
            EolMergeFixture.index(root).should eq(index)
            if conflict
              result.conflicts.should eq(["file.txt"])
              repository.merge.abort
              repository.head.oid.should eq(ours)
              expected_original = attributes[0] == EolMergeFixture::CRLF ? "OURS\r\n" : "OURS\n"
              File.read(File.join(root, "file.txt")).should eq(expected_original)
            else
              result.commit_oid.should_not be_nil
              repository.read_head_file("file.txt").should eq("OURS\ntwo\nTHEIRS\n")
              repository.read_commit(repository.head.oid.not_nil!).parents.should eq([ours, theirs])
              repository.working_changes.should be_empty
            end
          end
        end
      end
    end

    it "uses conflicted #{format} attribute marker content as the result source" do
      GitOracle.with_repo(format: format) do |root|
        repository, _, _ = EolMergeFixture.divergent(root, EolMergeFixture::LF, EolMergeFixture::CRLF,
          base_attributes: "*.txt text\n", conflict: true)
        expected, index = EolMergeFixture.oracle(root, "file.txt")
        EolMergeFixture.merge(repository).conflicts.should eq([".gitattributes", "file.txt"])
        File.read(File.join(root, "file.txt")).should eq(expected)
        expected.should contain("\r\n")
        EolMergeFixture.index(root).should eq(index)
        repository.merge.abort
      end
    end

    it "honors deleted and nested #{format} planned attributes" do
      GitOracle.with_repo(format: format) do |root|
        repository, _, _ = EolMergeFixture.divergent(root, EolMergeFixture::CRLF, nil,
          path: "nested/file.txt", attribute_path: "nested/.gitattributes")
        expected, index = EolMergeFixture.oracle(root, "nested/file.txt")
        EolMergeFixture.merge(repository)
        File.read(File.join(root, "nested", "file.txt")).should eq(expected)
        expected.should eq("OURS\ntwo\nTHEIRS\n")
        File.exists?(File.join(root, "nested", ".gitattributes")).should be_false
        EolMergeFixture.index(root).should eq(index)
      end
    end

    it "stages a resolved #{format} conflict canonically before continuing" do
      GitOracle.with_repo(format: format) do |root|
        repository, ours, theirs = EolMergeFixture.divergent(root, conflict: true)
        EolMergeFixture.merge(repository)
        File.write(File.join(root, "file.txt"), "resolved\r\n")
        repository.stage_file("file.txt")
        oid = repository.merge.continue(author: EolMergeFixture::SIGNATURE, committer: EolMergeFixture::SIGNATURE)
        repository.read_commit(oid).parents.should eq([ours, theirs])
        repository.read_head_file("file.txt").should eq("resolved\n")
        File.read(File.join(root, "file.txt")).should eq("resolved\r\n")
        repository.merge.in_progress?.should be_false
        repository.working_changes.should be_empty
      end
    end

    ["node", "node~HEAD"].each do |matched|
      it "converts #{format} relocated conflicts using the final #{matched} attribute rule" do
        GitOracle.with_repo(format: format) do |root|
          repository = Git::Repository.new(root)
          attributes = "#{matched} text eol=crlf\n"
          base = EolMergeFixture.commit(repository, {".gitattributes" => attributes})
          ours = EolMergeFixture.commit(repository, {".gitattributes" => attributes, "node" => "ours\n"}, [base])
          theirs = EolMergeFixture.commit(repository, {".gitattributes" => attributes, "node/child" => "theirs\n"}, [base])
          EolMergeFixture.install(repository, ours, theirs)
          expected, index = EolMergeFixture.oracle(root, "node~HEAD")
          EolMergeFixture.merge(repository).conflicts.should eq(["node~HEAD"])
          File.read(File.join(root, "node~HEAD")).should eq(expected)
          EolMergeFixture.index(root).should eq(index)
          repository.merge.abort
          File.read(File.join(root, "node")).should eq(matched == "node" ? "ours\r\n" : "ours\n")
          File.exists?(File.join(root, "node~HEAD")).should be_false
        end
      end
    end
  end
end

describe "native merge conversion guards and forwarding" do
  ["sha1", "sha256"].each do |format|
    ["fast_forward", "merge"].each do |operation|
      it "forwards explicit #{format} config through #{operation}'s fast-forward path" do
        GitOracle.with_repo(format: format) do |root|
          repository = Git::Repository.new(root)
          first = EolMergeFixture.commit(repository, {"file.txt" => "first\n"})
          tip = EolMergeFixture.commit(repository, {"file.txt" => "second\n"}, [first])
          EolMergeFixture.install(repository, first, tip)
          config = repository.config(command_values: [{"core.autocrlf", "true"}] of {String, String?})
          if operation == "fast_forward"
            repository.fast_forward("topic", config: config).target_oid.should eq(tip)
          else
            EolMergeFixture.merge(repository, config: config).commit_oid.should eq(tip)
          end
          File.read(File.join(root, "file.txt")).should eq("second\r\n")
          repository.read_head_file("file.txt").should eq("second\n")
          repository.working_changes(config: config).should be_empty
          GitOracle.run(root, "-c", "core.autocrlf=true", "status", "--porcelain").stdout.should eq("")
        end
      end
    end

    [false, true].each do |diverged|
      it "preserves unchanged #{format} file bytes across an attribute-only #{diverged ? "merge" : "fast-forward"}" do
        GitOracle.with_repo(format: format) do |root|
          repository = Git::Repository.new(root)
          original = {"file.txt" => "same\n", ".gitattributes" => EolMergeFixture::CRLF}
          base = EolMergeFixture.commit(repository, original)
          ours = diverged ? EolMergeFixture.commit(repository, original.merge({"ours" => "ours\n"}), [base]) : base
          theirs = EolMergeFixture.commit(repository, original.merge({".gitattributes" => EolMergeFixture::LF}), [base])
          EolMergeFixture.install(repository, ours, theirs)
          result = EolMergeFixture.merge(repository)
          result.changed_paths.should_not contain("file.txt")
          File.read(File.join(root, "file.txt")).should eq("same\r\n")
          repository.read_head_file("file.txt").should eq("same\n")
        end
      end
    end

    it "uses explicit #{format} conversion config for merge and original-tree abort" do
      GitOracle.with_repo(format: format) do |root|
        repository, ours, _ = EolMergeFixture.divergent(root, nil, nil, conflict: true)
        config = repository.config(command_values: [{"core.autocrlf", "true"}] of {String, String?})
        File.write(File.join(root, "file.txt"), "OURS\r\n")
        EolMergeFixture.merge(repository, config: config).conflicts.should eq(["file.txt"])
        File.read(File.join(root, "file.txt")).should eq("<<<<<<< HEAD\r\nOURS\r\n=======\r\nTHEIRS\r\n>>>>>>> topic\r\n")
        repository.merge.abort(config: config)
        File.read(File.join(root, "file.txt")).should eq("OURS\r\n")
        repository.head.oid.should eq(ours)
        repository.working_changes(config: config).should be_empty
      end
    end

    it "refuses an EOL-only #{format} racing replacement using the original raw identity" do
      GitOracle.with_repo(format: format) do |root|
        repository, ours, _ = EolMergeFixture.divergent(root)
        before = File.read(File.join(root, ".git", "index"))
        altered = false
        check = -> do
          if !altered && File.exists?(File.join(root, ".git", "MERGE_HEAD"))
            File.write(File.join(root, "file.txt"), "OURS\ntwo\nthree\n")
            altered = true
          end
          nil
        end
        error = expect_raises(Git::Merge::PartialPublication) { EolMergeFixture.merge(repository, check: check) }
        altered.should be_true
        error.changed_paths.should be_empty
        error.index_published.should be_false
        error.original_error.message.should match(/tracked file changed/)
        repository.head.oid.should eq(ours)
        File.read(File.join(root, ".git", "index")).should eq(before)
        File.read(File.join(root, "file.txt")).should eq("OURS\ntwo\nthree\n")
        repository.merge.abort
      end
    end

    it "recovers unpublished #{format} relocated CRLF outputs only under their exact raw receipt" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        attrs = "node~topic text eol=crlf\n"
        base = EolMergeFixture.commit(repository, {".gitattributes" => attrs})
        ours = EolMergeFixture.commit(repository, {".gitattributes" => attrs, "node/child" => "ours\n"}, [base])
        theirs = EolMergeFixture.commit(repository, {".gitattributes" => attrs, "node" => "theirs\n"}, [base])
        EolMergeFixture.install(repository, ours, theirs)
        before = EolMergeFixture.index(root)
        relocated = File.join(root, "node~topic")
        check = -> do
          raise Git::Error.new("injected after relocated publication") if File.exists?(relocated)
        end
        error = expect_raises(Git::Merge::PartialPublication) { EolMergeFixture.merge(repository, check: check) }
        error.index_published.should be_false
        File.read(relocated).should eq("theirs\r\n")
        raw = File.read(File.join(root, ".git", "CRYSTAL_MERGE_PATHS"))
        receipt = Git::Merge::Recovery.decode(raw, ours, theirs, repository.object_format, 8_388_608, 10_000)
        receipt.outputs["node~topic"].oid.should eq(Git::ObjectId.digest("blob", "theirs\r\n", repository.object_format))
        File.write(relocated, "theirs\n")
        expect_raises(Git::Error, /untracked or changed unpublished output/) { repository.merge.abort }
        File.read(relocated).should eq("theirs\n")
        repository.merge.in_progress?.should be_true
        File.write(relocated, "theirs\r\n")
        repository.merge.abort
        File.exists?(relocated).should be_false
        File.read(File.join(root, "node", "child")).should eq("ours\n")
        repository.head.oid.should eq(ours)
        EolMergeFixture.index(root).should eq(before)
      end
    end
  end

  it "rejects per-file CRLF expansion before merge metadata or worktree publication" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      base_files = {"file.txt" => "base\n", ".gitattributes" => EolMergeFixture::CRLF}
      base = EolMergeFixture.commit(repository, base_files)
      ours = EolMergeFixture.commit(repository, base_files.merge({"ours" => "ours\n"}), [base])
      theirs = EolMergeFixture.commit(repository, base_files.merge({"file.txt" => "a\n" * 180}), [base])
      EolMergeFixture.install(repository, ours, theirs)
      before = File.read(File.join(root, ".git", "index"))
      orig_head_path = File.join(root, ".git", "ORIG_HEAD")
      orig_head = File.exists?(orig_head_path) ? File.read(orig_head_path) : nil
      expect_raises(Git::Error, /budget/) { EolMergeFixture.merge(repository, max_object_bytes: 384) }
      repository.head.oid.should eq(ours)
      File.read(File.join(root, "file.txt")).should eq("base\r\n")
      File.read(File.join(root, ".git", "index")).should eq(before)
      ["MERGE_HEAD", "MERGE_MSG", "CRYSTAL_MERGE_ORIG", "CRYSTAL_MERGE_PATHS", "index.lock"].each do |name|
        File.exists?(File.join(root, ".git", name)).should be_false
      end
      (File.exists?(orig_head_path) ? File.read(orig_head_path) : nil).should eq(orig_head)
    end
  end

  it "rejects aggregate CRLF expansion before merge metadata publication" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      original = {"a.txt" => "a\n", "b.txt" => "b\n", ".gitattributes" => EolMergeFixture::CRLF}
      base = EolMergeFixture.commit(repository, original)
      ours = EolMergeFixture.commit(repository, original.merge({"ours" => "ours\n"}), [base])
      theirs = EolMergeFixture.commit(repository, original.merge({"a.txt" => "a\n" * 120, "b.txt" => "b\n" * 120}), [base])
      EolMergeFixture.install(repository, ours, theirs)
      before = File.read(File.join(root, ".git", "index"))
      expect_raises(Git::Error, /budget/) { EolMergeFixture.merge(repository, max_object_bytes: 512, max_total_bytes: 600) }
      repository.head.oid.should eq(ours)
      File.read(File.join(root, ".git", "index")).should eq(before)
      File.read(File.join(root, "a.txt")).should eq("a\r\n")
      File.exists?(File.join(root, ".git", "MERGE_HEAD")).should be_false
    end
  end
end

describe "native merge conversion preservation" do
  ["sha1", "sha256"].each do |format|
    [{EolMergeFixture::LF, EolMergeFixture::CRLF}, {EolMergeFixture::CRLF, EolMergeFixture::LF}].each do |attributes|
      it "fast-forwards clean #{format} predecessors using target #{attributes[1].strip} attributes" do
        GitOracle.with_repo(format: format) do |root|
          repository = Git::Repository.new(root)
          first = EolMergeFixture.commit(repository, {"file.txt" => "first\n", ".gitattributes" => attributes[0]})
          tip = EolMergeFixture.commit(repository, {"file.txt" => "second\n", ".gitattributes" => attributes[1]}, [first])
          EolMergeFixture.install(repository, first, tip)
          GitOracle.run(root, "merge", "--ff-only", "topic")
          expected = File.read(File.join(root, "file.txt"))
          index = EolMergeFixture.index(root)
          GitOracle.run(root, "reset", "--hard", "-q", first)
          repository.fast_forward("topic").target_oid.should eq(tip)
          File.read(File.join(root, "file.txt")).should eq(expected)
          EolMergeFixture.index(root).should eq(index)
          repository.read_head_file("file.txt").should eq("second\n")
        end
      end
    end

    it "uses nested #{format} result attributes when root attributes select LF" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        base_files = {".gitattributes" => EolMergeFixture::LF, "nested/file.txt" => "base\n"}
        base = EolMergeFixture.commit(repository, base_files)
        ours = EolMergeFixture.commit(repository, base_files.merge({"ours" => "ours\n"}), [base])
        theirs = EolMergeFixture.commit(repository, base_files.merge({"nested/.gitattributes" => EolMergeFixture::CRLF, "nested/file.txt" => "theirs\n"}), [base])
        EolMergeFixture.install(repository, ours, theirs)
        expected, index = EolMergeFixture.oracle(root, "nested/file.txt")
        EolMergeFixture.merge(repository)
        File.read(File.join(root, "nested", "file.txt")).should eq(expected)
        expected.should eq("theirs\r\n")
        EolMergeFixture.index(root).should eq(index)
      end
    end

    it "preserves #{format} binary payloads and raw symlink targets" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        attrs = "*.txt text eol=crlf\n*.bin -text\nlink text eol=crlf\n"
        base_files = {".gitattributes" => attrs, "file.txt" => "base\n", "raw.bin" => "base\0\n"}
        base = EolMergeFixture.commit(repository, base_files, symlinks: {"link" => "before\n"})
        ours = EolMergeFixture.commit(repository, base_files.merge({"ours" => "ours\n"}), [base], symlinks: {"link" => "before\n"})
        payload = "changed\0\r\nraw\n"
        theirs = EolMergeFixture.commit(repository, base_files.merge({"file.txt" => "theirs\n", "raw.bin" => payload}), [base], symlinks: {"link" => "after\n"})
        EolMergeFixture.install(repository, ours, theirs)
        EolMergeFixture.merge(repository)
        File.read(File.join(root, "file.txt")).should eq("theirs\r\n")
        File.read(File.join(root, "raw.bin")).should eq(payload)
        File.readlink(File.join(root, "link")).should eq("after\n")
        entry = repository.index_entries.find { |candidate| candidate.path == "raw.bin" }.not_nil!
        repository.read_object(entry.oid).should eq(Git::RawObject.new(Git::ObjectType::Blob, payload))
        GitOracle.run(root, "show", "HEAD:link").stdout.should eq("after\n")
        repository.working_changes.should be_empty
      end
    end
  end

  [false, true].each do |diverged|
    it "forwards selected conversion config through a #{diverged ? "diverged" : "fast-forward"} pull" do
      GitOracle.with_repo do |root|
        repository = Git::Repository.new(root)
        first = EolMergeFixture.commit(repository, {"file.txt" => "first\n"})
        tip = EolMergeFixture.commit(repository, {"file.txt" => "second\n"}, [first])
        ours = diverged ? EolMergeFixture.commit(repository, {"file.txt" => "first\n", "ours" => "ours\n"}, [first]) : first
        EolMergeFixture.install(repository, ours, tip)
        remote = File.join(File.dirname(root), "remote.git")
        GitOracle.run(root, "clone", "--bare", "-q", root, remote)
        GitOracle.run(remote, "update-ref", "refs/heads/main", tip)
        repository.remotes.add("origin", remote)
        repository.branches.set_upstream("main", Git::Branch::Upstream.new("origin", "refs/heads/main"))
        config = repository.config(command_values: [{"core.autocrlf", "true"}] of {String, String?})
        result = repository.pull(mode: Git::Pull::Mode::Merge, author: EolMergeFixture::SIGNATURE, config: config)
        result.action.should eq(diverged ? Git::Pull::Action::Merge : Git::Pull::Action::FastForward)
        File.read(File.join(root, "file.txt")).should eq("second\r\n")
        repository.read_head_file("file.txt").should eq("second\n")
        repository.working_changes(config: config).should be_empty
      end
    end
  end
end

describe "native merge conversion recovery boundaries" do
  ["sha1", "sha256"].each do |format|
    it "materializes original #{format} CRLF bytes even when abort sees the canonical original blob" do
      GitOracle.with_repo(format: format) do |root|
        repository, ours, _ = EolMergeFixture.divergent(root, conflict: true)
        EolMergeFixture.merge(repository)
        File.write(File.join(root, "file.txt"), "OURS\n")
        repository.merge.abort
        File.read(File.join(root, "file.txt")).should eq("OURS\r\n")
        repository.head.oid.should eq(ours)
        repository.working_changes.should be_empty
      end
    end

    it "refuses genuinely dirty #{format} CRLF content before starting a merge" do
      GitOracle.with_repo(format: format) do |root|
        repository, ours, _ = EolMergeFixture.divergent(root)
        before = File.read(File.join(root, ".git", "index"))
        File.write(File.join(root, "file.txt"), "dirty\r\n")
        expect_raises(Git::Error, /dirty tracked files/) { EolMergeFixture.merge(repository) }
        repository.head.oid.should eq(ours)
        File.read(File.join(root, ".git", "index")).should eq(before)
        File.read(File.join(root, "file.txt")).should eq("dirty\r\n")
        repository.merge.in_progress?.should be_false
      end
    end
  end

  it "forwards explicit config through an initial pull checkout" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      tip = EolMergeFixture.commit(repository, {"file.txt" => "first\n"})
      repository.refs.update("refs/heads/main", tip, expected_oid: nil)
      destination = File.join(File.dirname(root), "initial-pull")
      Dir.mkdir(destination)
      pulled = Git::Repository.init(destination)
      pulled.remotes.add("origin", root)
      pulled.branches.set_upstream("main", Git::Branch::Upstream.new("origin", "refs/heads/main"))
      config = pulled.config(command_values: [{"core.autocrlf", "true"}] of {String, String?})
      pulled.pull(config: config).action.should eq(Git::Pull::Action::Initial)
      File.read(File.join(destination, "file.txt")).should eq("first\r\n")
      pulled.read_head_file("file.txt").should eq("first\n")
      pulled.working_changes(config: config).should be_empty
    end
  end

  it "retains a racing EOL-only replacement on the fast-forward publication path" do
    GitOracle.with_repo do |root|
      repository = Git::Repository.new(root)
      original = {"file.txt" => "first\n", ".gitattributes" => EolMergeFixture::CRLF}
      first = EolMergeFixture.commit(repository, original)
      tip = EolMergeFixture.commit(repository, original.merge({"file.txt" => "second\n"}), [first])
      EolMergeFixture.install(repository, first, tip)
      before = File.read(File.join(root, ".git", "index"))
      altered = false
      check = -> do
        if !altered && File.exists?(File.join(root, ".git", "index.lock"))
          File.write(File.join(root, "file.txt"), "first\n")
          altered = true
        end
        nil
      end
      error = expect_raises(Git::Reset::PartialPublication) { repository.fast_forward("topic", check: check) }
      altered.should be_true
      error.changed_worktree_paths.should be_empty
      error.index_published.should be_false
      error.reference_published.should be_false
      repository.head.oid.should eq(first)
      File.read(File.join(root, ".git", "index")).should eq(before)
      File.read(File.join(root, "file.txt")).should eq("first\n")
    end
  end
end
