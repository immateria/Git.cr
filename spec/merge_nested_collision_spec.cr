require "spec"
require "../src/git"
require "./support/git_oracle"

private module NestedCollisionFixture
  SIGNATURE = Git::Signature.new("Nested", "nested@example.test", 1234567890_i64, 0)

  def self.populate(root : String, files : Hash(String, String)) : Nil
    Dir.children(root).each do |name|
      File.delete(File.join(root, name)) unless name == ".git"
    end
    files.each { |path, data| File.write(File.join(root, path), data) }
    GitOracle.run(root, "add", "-A")
  end

  def self.start(repo : Git::Repository, operation : String) : Nil
    case operation
    when "merge"       then repo.merge("topic", author: SIGNATURE, committer: SIGNATURE, message: "merge")
    when "cherry-pick" then repo.cherry_pick("topic", committer: SIGNATURE)
    when "revert"      then repo.revert("topic", author: SIGNATURE, committer: SIGNATURE)
    else                    repo.rebase("main", committer: SIGNATURE)
    end
  end

  def self.abort(repo : Git::Repository, operation : String) : Nil
    case operation
    when "merge"       then repo.merge.abort
    when "cherry-pick" then repo.cherry_pick.abort
    when "revert"      then repo.revert.abort
    else                    repo.rebase.abort(committer: SIGNATURE)
    end
  end

  def self.continue(repo : Git::Repository, operation : String) : Nil
    case operation
    when "merge"       then repo.merge.continue(author: SIGNATURE, committer: SIGNATURE)
    when "cherry-pick" then repo.cherry_pick.continue(committer: SIGNATURE)
    when "revert"      then repo.revert.continue(committer: SIGNATURE)
    else                    repo.rebase.continue(committer: SIGNATURE).completed.should be_true
    end
  end
end

describe "Git nested rename/add source conflicts" do
  ["sha1", "sha256"].each do |format|
    [true, false].each do |rename_ours|
      ["text", "binary", "binary-base", "no-newline"].each do |content|
        ["merge", "cherry-pick", "revert", "rebase"].each do |operation|
          it "preserves #{format} #{content} #{operation} rename_ours=#{rename_ours} stages and worktree bytes" do
            GitOracle.with_repo(format: format) do |root|
              base = content == "binary" ? "\0" + "A" * 319 : (0...20).map { |i| "word#{i.to_s.rjust(2, '0')} stable content " }.join + "\n"
              base = "\0" + "A" * 319 if content == "binary-base"
              base = base.chomp if content == "no-newline"
              left = content == "binary" ? "\0" + "B" * 63 + "A" * 256 : base.sub("word02", "left02")
              right = content == "binary" ? "\0" + "C" * 63 + "A" * 256 : base.sub("word02", "rght02")
              left = "B" + "A" * 319 if content == "binary-base"
              right = "C" + "A" * 319 if content == "binary-base"
              addition = content == "no-newline" ? "independent addition" : "independent addition\n"
              ours = rename_ours ? {"new" => left} : {"old" => left, "new" => addition}
              theirs = rename_ours ? {"old" => right, "new" => addition} : {"new" => right}
              if operation == "revert"
                NestedCollisionFixture.populate(root, theirs)
                GitOracle.run(root, "commit", "-qm", "incoming parent")
                NestedCollisionFixture.populate(root, {"old" => base})
                GitOracle.run(root, "commit", "-qm", "to revert")
                GitOracle.run(root, "branch", "topic")
              else
                NestedCollisionFixture.populate(root, {"old" => base})
                GitOracle.run(root, "commit", "-qm", "base")
                GitOracle.run(root, "checkout", "-qb", "topic")
                NestedCollisionFixture.populate(root, theirs)
                GitOracle.run(root, "commit", "-qm", "incoming")
                GitOracle.run(root, "checkout", "-q", "main")
              end
              NestedCollisionFixture.populate(root, ours)
              GitOracle.run(root, "commit", "-qm", "ours")
              GitOracle.run(root, "checkout", "-q", "topic") if operation == "rebase"
              original_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
              original_index = GitOracle.run(root, "ls-files", "-s").stdout
              args = case operation
                     when "merge"  then ["merge", "--no-commit", "--no-ff", "topic"]
                     when "rebase" then ["rebase", "main"]
                     else               [operation, "topic"]
                     end
              GitOracle.run_args(root, args, check: false).exit_code.should eq(1)
              expected_index = GitOracle.run(root, "ls-files", "-s").stdout
              expected_content = File.read(File.join(root, "new"))
              GitOracle.run(root, "ls-files", "-u").stdout.should_not contain("\told\n")
              GitOracle.run(root, operation, "--abort")
              repo = Git::Repository.new(root)
              NestedCollisionFixture.start(repo, operation)
              GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
              File.read(File.join(root, "new")).should eq(expected_content)
              File.exists?(File.join(root, "old")).should be_false
              NestedCollisionFixture.abort(repo, operation)
              GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(original_head)
              GitOracle.run(root, "ls-files", "-s").stdout.should eq(original_index)
              GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
              NestedCollisionFixture.start(repo, operation)
              File.write(File.join(root, "new"), "resolved\n")
              GitOracle.run(root, "add", "-A")
              NestedCollisionFixture.continue(repo, operation)
              GitOracle.run(root, "ls-files", "-u").stdout.should eq("")
              GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
              GitOracle.run(root, "fsck", "--strict").success?.should be_true
            end
          end
        end
      end
    end
  end
end

describe "Git nested rename/add bounds" do
  ["sha1", "sha256"].each do |format|
    ["marker-budget", "invalid-encoding", "different-source-kind"].each do |scenario|
      it "refuses #{format} #{scenario} before mutable publication" do
        GitOracle.with_repo(format: format) do |root|
          base = (0...32).map { |i| "word#{i.to_s.rjust(2, '0')} stable content " }.join + "\n"
          prefix = scenario == "invalid-encoding" ? String.new(Bytes[0xff]) : ""
          NestedCollisionFixture.populate(root, {"old" => prefix + base})
          GitOracle.run(root, "commit", "-qm", "base")
          GitOracle.run(root, "checkout", "-qb", "topic")
          NestedCollisionFixture.populate(root, {"old" => prefix + base.sub("word02", "rght02"), "new" => "addition\n"})
          if scenario == "different-source-kind"
            File.delete(File.join(root, "old"))
            File.symlink("target", File.join(root, "old"))
            GitOracle.run(root, "add", "-A")
          end
          GitOracle.run(root, "commit", "-qm", "incoming")
          GitOracle.run(root, "checkout", "-q", "main")
          left = prefix + base.sub("word02", "left02")
          NestedCollisionFixture.populate(root, {"new" => left})
          GitOracle.run(root, "commit", "-qm", "ours")
          before_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
          before_index = GitOracle.run(root, "ls-files", "-s").stdout
          repo = Git::Repository.new(root)
          expected = case scenario
                     when "marker-budget"    then /marker budget/
                     when "invalid-encoding" then /text encoding/
                     else                         /differing source types/
                     end
          expect_raises(Git::Error, expected) do
            repo.merge("topic", author: NestedCollisionFixture::SIGNATURE,
              committer: NestedCollisionFixture::SIGNATURE, message: "merge",
              max_object_bytes: scenario == "marker-budget" ? 1024 : 8_388_608)
          end
          File.read(File.join(root, "new")).to_slice.should eq(left.to_slice)
          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(before_head)
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(before_index)
          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
          File.exists?(File.join(root, ".git/MERGE_HEAD")).should be_false
          File.exists?(File.join(root, ".git/CRYSTAL_MERGE_PATHS")).should be_false
          File.exists?(File.join(root, ".git/index.lock")).should be_false
        end
      end
    end
  end
end

private module NestedCollisionFixture
  def self.commit(repo : Git::Repository, files : Hash(String, String), parents : Array(String), time : Int64) : String
    tree = repo.write_tree(files.map { |name, data| Git::Tree::Entry.new(name, "100644", repo.write_blob(data)) })
    sig = Git::Signature.new("Nested", "nested@example.test", time, 0)
    repo.write_commit(tree: tree, parents: parents, author: sig, committer: sig, message: "fixture\n")
  end
end

describe "Git recursive nested rename/add conflicts" do
  ["sha1", "sha256"].each do |format|
    [true, false].each do |rename_ours|
      ["text", "binary"].each do |content|
        it "preserves #{format} #{content} rename_ours=#{rename_ours} virtual-base collision blobs" do
          GitOracle.with_repo(format: format) do |root|
            repo = Git::Repository.new(root)
            base = content == "binary" ? "\0" + "A" * 319 : (0...20).map { |i| "word#{i.to_s.rjust(2, '0')} stable content " }.join + "\n"
            left = content == "binary" ? "\0" + "B" * 63 + "A" * 256 : base.sub("word02", "left02")
            right = content == "binary" ? "\0" + "C" * 63 + "A" * 256 : base.sub("word02", "rght02")
            first = NestedCollisionFixture.commit(repo, {"old" => base}, [] of String, 1234567890_i64)
            left_files = rename_ours ? {"new" => left} : {"old" => left, "new" => "addition\n"}
            right_files = rename_ours ? {"old" => right, "new" => "addition\n"} : {"new" => right}
            a = NestedCollisionFixture.commit(repo, left_files, [first], 1234567891_i64)
            b = NestedCollisionFixture.commit(repo, right_files, [first], 1234567892_i64)
            ours = NestedCollisionFixture.commit(repo, {"new" => "ours\n"}, [a, b], 1234567893_i64)
            theirs = NestedCollisionFixture.commit(repo, {"new" => "theirs\n"}, [b, a], 1234567894_i64)
            GitOracle.run(root, "update-ref", "refs/heads/main", ours)
            GitOracle.run(root, "update-ref", "refs/heads/topic", theirs)
            GitOracle.run(root, "reset", "--hard", "main")
            GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false).exit_code.should eq(1)
            expected_index = GitOracle.run(root, "ls-files", "-s").stdout
            expected_content = File.read(File.join(root, "new"))
            GitOracle.run(root, "merge", "--abort")
            repo.merge("topic", author: NestedCollisionFixture::SIGNATURE,
              committer: NestedCollisionFixture::SIGNATURE, message: "merge")
            GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
            File.read(File.join(root, "new")).should eq(expected_content)
            repo.merge.abort
            GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
          end
        end
      end
    end
  end
end

describe "Git nested collision destination resolution" do
  ["sha1", "sha256"].each do |format|
    [true, false].each do |rename_ours|
      ["content-mode", "equal", "equal-mode", "outer-budget"].each do |scenario|
        it "preserves #{format} #{scenario} rename_ours=#{rename_ours} destination semantics" do
          GitOracle.with_repo(format: format) do |root|
            base = (0...20).map { |i| "word#{i.to_s.rjust(2, '0')} stable content " }.join + "\n"
            left = base.sub("word02", "left02")
            right = base.sub("word02", "rght02")
            addition = scenario == "outer-budget" ? "addition " * 32 + "\n" : "addition\n"
            NestedCollisionFixture.populate(root, {"old" => base})
            GitOracle.run(root, "commit", "-qm", "base")
            GitOracle.run(root, "checkout", "-qb", "topic")
            NestedCollisionFixture.populate(root, rename_ours ? {"old" => right, "new" => addition} : {"new" => right})
            if scenario == "content-mode" && !rename_ours
              File.chmod(File.join(root, "new"), 0o755)
              GitOracle.run(root, "add", "-A")
            end
            GitOracle.run(root, "commit", "-qm", "incoming")
            GitOracle.run(root, "checkout", "-q", "main")
            NestedCollisionFixture.populate(root, rename_ours ? {"new" => left} : {"old" => left, "new" => addition})
            if scenario == "content-mode" && rename_ours
              File.chmod(File.join(root, "new"), 0o755)
              GitOracle.run(root, "add", "-A")
            end
            GitOracle.run(root, "commit", "-qm", "ours")
            GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false).exit_code.should eq(1)
            stage = rename_ours ? "2" : "3"
            source_entry = GitOracle.run(root, "ls-files", "-u").stdout.lines.find do |line|
              line.split('\t', 2)[0].ends_with?(" #{stage}")
            end.not_nil!
            source_blob = GitOracle.run(root, "cat-file", "blob", source_entry.split(' ')[1]).stdout
            GitOracle.run(root, "merge", "--abort")
            if scenario.starts_with?("equal")
              GitOracle.run(root, "checkout", "-q", rename_ours ? "topic" : "main")
              File.write(File.join(root, "new"), source_blob)
              File.chmod(File.join(root, "new"), scenario == "equal-mode" ? 0o755 : 0o644)
              GitOracle.run(root, "add", "-A")
              GitOracle.run(root, "commit", "--amend", "--no-edit")
              GitOracle.run(root, "checkout", "-q", "main")
            end
            before_head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
            before_index = GitOracle.run(root, "ls-files", "-s").stdout
            before_file = File.read(File.join(root, "new"))
            oracle = GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false)
            oracle.exit_code.should eq(scenario == "equal" ? 0 : 1)
            expected_index = GitOracle.run(root, "ls-files", "-s").stdout
            expected_content = File.read(File.join(root, "new"))
            expected_executable = File.info(File.join(root, "new")).permissions.value & 0o111 != 0
            GitOracle.run(root, "merge", "--abort")
            repo = Git::Repository.new(root)
            if scenario == "outer-budget"
              source_blob.bytesize.should be <= 1024
              expected_content.bytesize.should be > 1024
              expect_raises(Git::Error, /marker budget/) do
                repo.merge("topic", author: NestedCollisionFixture::SIGNATURE,
                  committer: NestedCollisionFixture::SIGNATURE, message: "merge", max_object_bytes: 1024)
              end
              GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(before_head)
              GitOracle.run(root, "ls-files", "-s").stdout.should eq(before_index)
              File.read(File.join(root, "new")).should eq(before_file)
              File.exists?(File.join(root, ".git/MERGE_HEAD")).should be_false
              File.exists?(File.join(root, ".git/CRYSTAL_MERGE_PATHS")).should be_false
            else
              result = repo.merge("topic", author: NestedCollisionFixture::SIGNATURE,
                committer: NestedCollisionFixture::SIGNATURE, message: "merge")
              result.conflicts.empty?.should eq(oracle.exit_code == 0)
              GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
              File.read(File.join(root, "new")).should eq(expected_content)
              (File.info(File.join(root, "new")).permissions.value & 0o111 != 0).should eq(expected_executable)
              repo.merge.abort unless result.conflicts.empty?
            end
            GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
          end
        end
      end
    end
  end
end

describe "Git structural rename/delete destination equality" do
  ["sha1", "sha256"].each do |format|
    [true, false].each do |rename_ours|
      it "retains #{format} structural conflict stages without duplicate markers rename_ours=#{rename_ours}" do
        GitOracle.with_repo(format: format) do |root|
          original = (0...20).map { |i| "word#{i.to_s.rjust(2, '0')} stable content " }.join + "\n"
          shared = original.sub("word02", "moved2")
          NestedCollisionFixture.populate(root, {"old" => original, "other" => shared})
          GitOracle.run(root, "commit", "-qm", "base")
          # One side edits+renames old. The other exactly renames other and
          # deletes old. Exact matching prevents its new from pairing to old.
          renamed = {"new" => shared, "other" => shared}
          deleted = {"new" => shared}
          GitOracle.run(root, "checkout", "-qb", "topic")
          NestedCollisionFixture.populate(root, rename_ours ? deleted : renamed)
          GitOracle.run(root, "commit", "-qm", "incoming")
          GitOracle.run(root, "checkout", "-q", "main")
          NestedCollisionFixture.populate(root, rename_ours ? renamed : deleted)
          GitOracle.run(root, "commit", "-qm", "ours")
          GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false).exit_code.should eq(1)
          expected = GitOracle.run(root, "ls-files", "-s").stdout
          expected_content = File.read(File.join(root, "new"))
          GitOracle.run(root, "merge", "--abort")
          repo = Git::Repository.new(root)
          result = repo.merge("topic", author: NestedCollisionFixture::SIGNATURE,
            committer: NestedCollisionFixture::SIGNATURE, message: "merge")
          result.conflicts.should eq(["new"])
          GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected)
          File.read(File.join(root, "new")).should eq(expected_content)
          repo.merge.abort
          GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
        end
      end
    end
  end
end
