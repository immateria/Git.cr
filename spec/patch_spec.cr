require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

private def oracle_diff(root : String, *args) : String
  GitOracle.run_args(root, ["diff", "--no-color"] + args.to_a.map(&.as(String))).stdout
end

private def same(actual : String, expected : String, label : String = "") : Nil
  return if actual == expected
  dir = File.tempname("patch-same")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "expected"), expected)
  File.write(File.join(dir, "actual"), actual)
  delta = IO::Memory.new
  Process.run("diff", ["-u", File.join(dir, "expected"), File.join(dir, "actual")], output: delta)
  FileUtils.rm_rf(dir)
  fail "patch differs from the oracle #{label}\n#{delta}"
end

private def commit_all(root : String, message : String = "c") : Nil
  GitOracle.run(root, "add", "-A")
  GitOracle.run(root, "commit", "-qm", message)
end

private def write(root : String, name : String, content : String | Bytes) : Nil
  path = File.join(root, name)
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
end

private def numbered(count : Int32, prefix : String = "line") : Array(String)
  (1..count).map { |i| "#{prefix} #{i}\n" }
end

private def lines_of(count : Int32, edits : Hash(Int32, String) = {} of Int32 => String) : String
  numbered(count).map_with_index { |line, i| edits[i + 1]? || line }.join
end

# One file per kind of change, committed as the baseline.
private def baseline(root : String) : Nil
  write(root, "modify.txt", lines_of(30))
  write(root, "delete.txt", "going away\n")
  write(root, "mode.sh", "#!/bin/sh\necho hi\n")
  write(root, "modemod.txt", lines_of(12))
  write(root, "binary.dat", Bytes[0, 1, 2, 3, 10, 4, 5])
  write(root, "latin1.txt", Bytes[0x63, 0x61, 0x66, 0xe9, 0x0a, 0x6f, 0x6e, 0x65, 0x0a])
  write(root, "nonl.txt", "first\nsecond")
  write(root, "swap", "plain file\n")
  write(root, "orig.txt", "to be renamed\nwith two lines\n")
  write(root, "dir/nested.txt", "nested\n")
  write(root, "sp ace.txt", "space\n")
  write(root, "tab\tname.txt", "tab\n")
  write(root, "café.txt", "unicode\n")
  write(root, "quote\"d.txt", "quote\n")
  File.symlink("modify.txt", File.join(root, "link"))
  commit_all(root, "baseline")
  GitOracle.run(root, "update-index", "--add", "--cacheinfo", "160000,#{"1" * 40},sub")
  GitOracle.run(root, "commit", "-qm", "gitlink")
  Dir.mkdir_p(File.join(root, "sub"))
end

# Edits in the working tree only; new files stay untracked.
private def edit_worktree(root : String) : Nil
  write(root, "modify.txt", lines_of(30, {3 => "three changed\n", 4 => "four changed\n", 20 => "twenty changed\n"}))
  File.delete(File.join(root, "delete.txt"))
  File.chmod(File.join(root, "mode.sh"), 0o755)
  write(root, "modemod.txt", lines_of(12, {6 => "six\n"}))
  File.chmod(File.join(root, "modemod.txt"), 0o755)
  write(root, "binary.dat", Bytes[0, 1, 2, 9, 10, 4, 5])
  write(root, "latin1.txt", Bytes[0x63, 0x61, 0x66, 0xe8, 0x0a, 0x6f, 0x6e, 0x65, 0x0a])
  write(root, "nonl.txt", "first\nsecond\nthird")
  File.delete(File.join(root, "swap"))
  File.symlink("modify.txt", File.join(root, "swap"))
  File.delete(File.join(root, "link"))
  File.symlink("other-target", File.join(root, "link"))
  File.rename(File.join(root, "orig.txt"), File.join(root, "renamed.txt"))
  write(root, "dir/nested.txt", "nested\nmore\n")
  write(root, "sp ace.txt", "space\nchanged\n")
  write(root, "tab\tname.txt", "tab\nchanged\n")
  write(root, "café.txt", "unicode\nchanged\n")
  write(root, "quote\"d.txt", "quote\nchanged\n")
end

# Additions and an unrelated gitlink move, staged on top of the edits.
private def stage_everything(root : String) : Nil
  write(root, "added.txt", "brand new\n")
  write(root, "added.bin", Bytes[0, 255, 0])
  write(root, "empty.txt", "")
  write(root, "dir/no newline.txt", "tail")
  GitOracle.run(root, "add", "-A")
  GitOracle.run(root, "update-index", "--add", "--cacheinfo", "160000,#{"2" * 40},sub")
end

describe "Git patch output" do
  it "matches git diff for a worktree with every kind of change" do
    GitOracle.with_repo do |root|
      baseline(root)
      edit_worktree(root)
      repo = Git::Repository.new(root)
      expected = oracle_diff(root)
      expected.should contain("Binary files a/binary.dat and b/binary.dat differ")
      same(repo.diff.to_s, expected)
      same(repo.diff("HEAD").to_s, oracle_diff(root, "HEAD"))
      same(repo.diff("HEAD~1").to_s, oracle_diff(root, "HEAD~1"))
    end
  end

  it "matches git diff --cached, including renames, additions and gitlinks" do
    GitOracle.with_repo do |root|
      baseline(root)
      edit_worktree(root)
      stage_everything(root)
      repo = Git::Repository.new(root)
      cached = oracle_diff(root, "--cached")
      cached.should contain("rename from orig.txt")
      cached.should contain("-Subproject commit #{"1" * 40}")
      same(repo.diff(cached: true).to_s, cached)
      same(repo.diff("HEAD", cached: true).to_s, cached)
      same(repo.diff("HEAD~1", cached: true).to_s, oracle_diff(root, "--cached", "HEAD~1"))
      repo.diff.to_s.should eq("")
      same(repo.diff("HEAD").to_s, oracle_diff(root, "HEAD"))
    end
  end

  it "matches git diff a b and git show for a commit" do
    GitOracle.with_repo do |root|
      baseline(root)
      edit_worktree(root)
      stage_everything(root)
      commit_all(root, "changes")
      repo = Git::Repository.new(root)
      expected = oracle_diff(root, "HEAD~1", "HEAD")
      expected.should contain("similarity index 100%")
      same(repo.diff("HEAD~1", "HEAD").to_s, expected)
      same(repo.diff("HEAD~2", "HEAD").to_s, oracle_diff(root, "HEAD~2", "HEAD"))
      shown = GitOracle.run(root, "show", "--format=", "--no-color", "HEAD").stdout
      same(shown, expected)
      same(repo.commit_patch.to_s, shown)
      same(repo.commit_patch("HEAD~1").to_s, GitOracle.run(root, "show", "--format=", "--no-color", "HEAD~1").stdout)
    end
  end

  it "diffs a root commit against the empty tree" do
    GitOracle.with_repo do |root|
      write(root, "a.txt", "one\ntwo\n")
      write(root, "b/c.txt", "three")
      commit_all(root)
      repo = Git::Repository.new(root)
      shown = GitOracle.run(root, "show", "--format=", "--no-color", "HEAD").stdout
      shown.should contain("new file mode 100644")
      same(repo.commit_patch.to_s, shown)
    end
  end

  it "diffs staged files against an unborn HEAD" do
    GitOracle.with_repo do |root|
      write(root, "a.txt", "one\n")
      GitOracle.run(root, "add", "a.txt")
      same(Git::Repository.new(root).diff(cached: true).to_s, oracle_diff(root, "--cached"))
    end
  end

  it "describes each file with its status, paths, modes, OIDs and text" do
    GitOracle.with_repo do |root|
      baseline(root)
      edit_worktree(root)
      stage_everything(root)
      patch = Git::Repository.new(root).diff(cached: true)
      by_path = patch.map { |file| {file.path, file} }.to_h
      patch.size.should eq(patch.to_a.size)
      patch.map(&.text).join.should eq(patch.to_s)
      by_path["added.txt"].status.should eq('A')
      by_path["added.txt"].old_path.should be_nil
      by_path["added.txt"].new_mode.should eq("100644")
      by_path["added.txt"].new_oid.should eq(GitOracle.run(root, "rev-parse", ":added.txt").stdout.strip)
      by_path["delete.txt"].status.should eq('D')
      by_path["delete.txt"].new_oid.should be_nil
      renamed = by_path["renamed.txt"]
      renamed.status.should eq('R')
      renamed.old_path.should eq("orig.txt")
      renamed.old_oid.should eq(renamed.new_oid)
      by_path["modify.txt"].status.should eq('M')
      by_path["binary.dat"].binary?.should be_true
      by_path["modify.txt"].binary?.should be_false
      by_path["modify.txt"].old_mode.should eq("100644")
      by_path["mode.sh"].new_mode.should eq("100755")
      patch.count { |file| file.path == "swap" }.should eq(2)
    end
  end

  it "limits the patch to paths and honours context" do
    GitOracle.with_repo do |root|
      baseline(root)
      edit_worktree(root)
      repo = Git::Repository.new(root)
      same(repo.diff(paths: ["modify.txt"]).to_s, oracle_diff(root, "--", "modify.txt"))
      same(repo.diff(paths: ["dir"]).to_s, oracle_diff(root, "--", "dir"))
      same(repo.diff(paths: ["dir", "link"]).to_s, oracle_diff(root, "--", "dir", "link"))
      [0, 1, 2, 5, 40].each do |context|
        same(repo.diff(context: context).to_s, oracle_diff(root, "-U#{context}"), "context #{context}")
      end
      same(repo.diff("HEAD", context: 0, paths: ["modify.txt"]).to_s, oracle_diff(root, "-U0", "HEAD", "--", "modify.txt"))
      expect_raises(ArgumentError) { repo.diff(context: -1) }
    end
  end

  it "prints no patch when nothing differs" do
    GitOracle.with_repo do |root|
      baseline(root)
      repo = Git::Repository.new(root)
      repo.diff.to_s.should eq("")
      repo.diff.size.should eq(0)
      repo.diff(cached: true).to_s.should eq("")
      repo.diff("HEAD").to_s.should eq("")
      repo.diff("HEAD", "HEAD").to_s.should eq("")
    end
  end

  it "keeps a rename out of the patch when renames is off" do
    GitOracle.with_repo do |root|
      write(root, "old.txt", "same\ncontent\n")
      commit_all(root)
      File.rename(File.join(root, "old.txt"), File.join(root, "new.txt"))
      commit_all(root, "move")
      repo = Git::Repository.new(root)
      same(repo.commit_patch.to_s, GitOracle.run(root, "show", "--format=", "--no-color", "HEAD").stdout)
      same(repo.commit_patch(renames: false).to_s, GitOracle.run(root, "show", "--format=", "--no-color", "--no-renames", "HEAD").stdout)
    end
  end

  it "abbreviates object IDs like git, longer when asked" do
    GitOracle.with_repo do |root|
      baseline(root)
      edit_worktree(root)
      repo = Git::Repository.new(root)
      same(repo.diff(abbrev: 12).to_s, oracle_diff(root, "--abbrev=12"))
      same(repo.diff(abbrev: 40).to_s, oracle_diff(root, "--full-index"))
      expect_raises(ArgumentError) { repo.diff(abbrev: 3) }
    end
  end

  it "extends an abbreviation that is ambiguous" do
    GitOracle.with_repo do |root|
      # Two blobs whose IDs share their first four hex digits.
      seen = {} of String => String
      pair = nil.as({String, String}?)
      i = 0
      until pair
        content = "blob #{i}\n"
        oid = Git::ObjectId.digest("blob", content)
        if other = seen[oid[0, 4]]?
          pair = {other, content}
        else
          seen[oid[0, 4]] = content
        end
        i += 1
      end
      first, second = pair.not_nil!
      write(root, "f.txt", first)
      commit_all(root)
      write(root, "f.txt", second)
      GitOracle.run(root, "hash-object", "-w", "--stdin", input: first)
      GitOracle.run(root, "hash-object", "-w", "--stdin", input: second)
      repo = Git::Repository.new(root)
      same(repo.diff(abbrev: 4).to_s, oracle_diff(root, "--abbrev=4"))
      same(repo.diff("HEAD", abbrev: 4).to_s, oracle_diff(root, "--abbrev=4", "HEAD"))
    end
  end

  it "refuses unmerged paths and a second revision without the first" do
    GitOracle.with_repo do |root|
      write(root, "f.txt", "base\n")
      commit_all(root)
      GitOracle.run(root, "checkout", "-q", "-b", "side")
      write(root, "f.txt", "side\n")
      commit_all(root, "side")
      GitOracle.run(root, "checkout", "-q", "main")
      write(root, "f.txt", "main\n")
      commit_all(root, "main")
      GitOracle.run(root, "merge", "side", check: false)
      repo = Git::Repository.new(root)
      expect_raises(Git::Error, /unmerged/) { repo.diff }
      expect_raises(Git::Error, /unmerged/) { repo.diff(cached: true) }
      expect_raises(ArgumentError) { repo.diff(nil, "HEAD") }
      expect_raises(ArgumentError) { repo.diff("HEAD", "HEAD", cached: true) }
    end
  end

  it "stops when the check callback raises" do
    GitOracle.with_repo do |root|
      baseline(root)
      edit_worktree(root)
      repo = Git::Repository.new(root)
      stop = -> { raise "cancelled" }
      expect_raises(Exception, "cancelled") { repo.diff(check: stop) }
    end
  end

  it "honours core.filemode=false" do
    GitOracle.with_repo do |root|
      write(root, "run.sh", "echo\n")
      commit_all(root)
      File.chmod(File.join(root, "run.sh"), 0o755)
      GitOracle.run(root, "config", "core.fileMode", "false")
      repo = Git::Repository.new(root)
      same(repo.diff(config: repo.config).to_s, oracle_diff(root))
      repo.diff.to_s.should contain("new mode 100755")
    end
  end
end

describe "Git patch line diff" do
  it "matches git on a file far past the old 700 line cap with scattered edits" do
    GitOracle.with_repo do |root|
      write(root, "big.txt", lines_of(5000))
      commit_all(root)
      edits = {} of Int32 => String
      (1..5000).step(97) { |i| edits[i] = "edited #{i}\n" }
      write(root, "big.txt", lines_of(5000, edits))
      repo = Git::Repository.new(root)
      patch = repo.diff
      same(patch.to_s, oracle_diff(root))
      patch.to_s.scan("@@ -").size.should be > 40
      same(repo.diff(context: 0).to_s, oracle_diff(root, "-U0"))
    end
  end

  it "matches git when every line of a large file changes" do
    GitOracle.with_repo do |root|
      write(root, "all.txt", numbered(3000, "old").join)
      commit_all(root)
      write(root, "all.txt", numbered(3000, "new").join)
      same(Git::Repository.new(root).diff.to_s, oracle_diff(root))
    end
  end

  it "matches git on insertions, deletions and moves in a large file" do
    GitOracle.with_repo do |root|
      old_lines = (1..2000).map { |i| "row #{i % 37} #{i}\n" }
      write(root, "mix.txt", old_lines.join)
      commit_all(root)
      changed = old_lines.dup
      changed.delete_at(1500)
      changed.insert(100, "inserted b\n")
      changed.insert(100, "inserted a\n")
      moved = changed[400, 30]
      30.times { changed.delete_at(400) }
      moved.reverse_each { |line| changed.insert(1200, line) }
      changed[1900] = "tail\n"
      write(root, "mix.txt", changed.join)
      same(Git::Repository.new(root).diff.to_s, oracle_diff(root))
    end
  end

  it "matches git for sliding hunks with and without the indent heuristic" do
    GitOracle.with_repo do |root|
      old_text = <<-TEXT
        def one
          a = 1
          b = 2
        end

        def two
          a = 1
          b = 2
        end

        def three
          x
        end

        TEXT
      new_text = <<-TEXT
        def one
          a = 1
          b = 2
        end

        def two
          a = 1
          b = 2
        end

        def inserted
          a = 1
          b = 2
        end

        def three
          x
        end

        TEXT
      write(root, "slide.rb", old_text + "\n")
      write(root, "repeat.txt", "a\nb\nb\nb\nc\n")
      write(root, "blocks.txt", "}\n\nfoo {\n  x\n}\n\nbar {\n  y\n}\n")
      commit_all(root)
      write(root, "slide.rb", new_text + "\n")
      write(root, "repeat.txt", "a\nb\nb\nb\nb\nc\n")
      write(root, "blocks.txt", "}\n\nfoo {\n  x\n}\n\nnew {\n  z\n}\n\nbar {\n  y\n}\n")
      repo = Git::Repository.new(root)
      same(repo.diff.to_s, oracle_diff(root))
      same(repo.diff(indent_heuristic: false).to_s, oracle_diff(root, "--no-indent-heuristic"))
    end
  end

  it "applies .gitattributes built-in xfuncname diff drivers and -diff/binary rules" do
    GitOracle.with_repo do |root|
      write(root, ".gitattributes", "*.[ch] diff=cpp\n*.py diff=python\n*.dat -diff\n")
      c_old = "int compute(int x)\n{\n  int a = 1;\n  int b = 2;\n  int c = 3;\nlabel_skip:\n  int d = 4;\n  int e = 5;\n  int f = 6;\n  return d + e + f;\n}\n"
      c_new = c_old.sub("return d + e + f;", "return d + e;")
      py_old = "  async def fetch_item(id):\n    a = 1\n    b = 2\n    c = 3\n    d = 4\n    return d\n"
      py_new = py_old.sub("return d", "return d + 1")
      write(root, "main.c", c_old)
      write(root, "app.py", py_old)
      write(root, "plain.dat", "text marked -diff\n")
      commit_all(root, "attr-base")
      write(root, "main.c", c_new)
      write(root, "app.py", py_new)
      write(root, "plain.dat", "changed text marked -diff\n")
      repo = Git::Repository.new(root)
      patch = repo.diff.to_s
      patch.should contain("@@ -7,5 +7,5 @@ int compute(int x)")
      patch.should contain("@@ -3,4 +3,4 @@ async def fetch_item(id):")
      patch.should contain("Binary files a/plain.dat and b/plain.dat differ")
      same(patch, oracle_diff(root))
    end
  end

  it "prints Git's function context after the hunk header" do
    GitOracle.with_repo do |root|
      body = (1..60).map { |i| i % 20 == 0 ? "def method_#{i}\n" : "  body #{i}\n" }.join
      write(root, "f.rb", body)
      commit_all(root)
      write(root, "f.rb", body.sub("body 45", "BODY 45").sub("body 3\n", "body three\n"))
      patch = Git::Repository.new(root).diff.to_s
      patch.should contain("@@ def method_40")
      same(patch, oracle_diff(root))
    end
  end

  it "refuses a diff over the line budget" do
    GitOracle.with_repo do |root|
      write(root, "f.txt", numbered(50).join)
      commit_all(root)
      write(root, "f.txt", numbered(50, "new").join)
      repo = Git::Repository.new(root)
      expect_raises(Git::Error, /budget/) { repo.diff(max_lines: 20) }
      repo.diff(max_lines: 100).size.should eq(1)
    end
  end

  it "fuzzes small random edits against git" do
    GitOracle.with_repo do |root|
      random = Random.new(20240607)
      40.times do |round|
        alphabet = ["a\n", "b\n", "c\n", "}\n", "\n", "  x\n", "  y\n", "d\n"]
        old_lines = Array.new(random.rand(0..40)) { alphabet.sample(random) }
        new_lines = old_lines.dup
        random.rand(0..6).times do
          case random.rand(3)
          when 0 then new_lines.insert(random.rand(0..new_lines.size), alphabet.sample(random))
          when 1 then new_lines.delete_at(random.rand(new_lines.size)) unless new_lines.empty?
          else        new_lines[random.rand(new_lines.size)] = alphabet.sample(random) unless new_lines.empty?
          end
        end
        write(root, "fuzz.txt", old_lines.join)
        GitOracle.run(root, "add", "-A")
        write(root, "fuzz.txt", new_lines.join)
        repo = Git::Repository.new(root)
        same(repo.diff.to_s, oracle_diff(root), "round #{round}: #{old_lines.inspect} -> #{new_lines.inspect}")
        same(repo.diff(indent_heuristic: false, context: 1).to_s, oracle_diff(root, "--no-indent-heuristic", "-U1"), "round #{round}")
      end
    end
  end
end

describe "Git patch submodules" do
  it "treats a gitlink whose directory is missing as deleted and an existing one as unchanged" do
    GitOracle.with_repo do |root|
      baseline(root)
      repo = Git::Repository.new(root)
      same(repo.diff.to_s, oracle_diff(root))
      Dir.delete(File.join(root, "sub"))
      same(repo.diff.to_s, oracle_diff(root))
      repo.diff.to_s.should contain("deleted file mode 160000")
      same(repo.diff("HEAD").to_s, oracle_diff(root, "HEAD"))
    end
  end
end

describe "Git patch line diff on heavily different files" do
  it "matches git where the Myers search hits its cost heuristics" do
    GitOracle.with_repo do |root|
      random = Random.new(7)
      [{3000, 40}, {3000, 4000}, {1500, 8}, {6000, 300}].each do |size, alphabet|
        old_text = Array.new(size) { "l#{random.rand(alphabet)}\n" }.join
        new_text = Array.new(size) { "l#{random.rand(alphabet)}\n" }.join
        write(root, "wide.txt", old_text)
        GitOracle.run(root, "add", "-A")
        write(root, "wide.txt", new_text)
        repo = Git::Repository.new(root)
        same(repo.diff.to_s, oracle_diff(root), "size #{size} alphabet #{alphabet}")
        same(repo.diff(indent_heuristic: false, context: 0).to_s, oracle_diff(root, "--no-indent-heuristic", "-U0"), "size #{size} alphabet #{alphabet}")
      end
    end
  end
end
