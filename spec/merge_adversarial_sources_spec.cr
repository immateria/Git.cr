require "spec"
require "../src/git"
require "./support/git_oracle"

private module AdversarialMergeSources
  SIGNATURE = Git::Signature.new("Audit", "audit@example.test", 1234567900_i64, 0)
  ALPHA     = "alpha alpha alpha alpha alpha\n"
  BRAVO     = "bravo bravo bravo bravo bravo\n"

  def self.commit(repo : Git::Repository, files : Hash(String, String), parents : Array(String),
                  time : Int64, executable : String = "", symlink : String = "") : String
    tree = repo.write_tree(files.map do |name, data|
      mode = name == symlink ? "120000" : (name == executable ? "100755" : "100644")
      Git::Tree::Entry.new(name, mode, repo.write_blob(data))
    end)
    sig = Git::Signature.new("Audit", "audit@example.test", time, 0)
    repo.write_commit(tree: tree, parents: parents, author: sig, committer: sig, message: "fixture\n")
  end

  def self.compare(root : String, repo : Git::Repository, ours : String, theirs : String) : Nil
    GitOracle.run(root, "update-ref", "refs/heads/main", ours)
    GitOracle.run(root, "update-ref", "refs/heads/topic", theirs)
    GitOracle.run(root, "reset", "--hard", "main")
    original_index = GitOracle.run(root, "ls-files", "-s").stdout
    GitOracle.run(root, "merge", "--no-commit", "--no-ff", "topic", check: false).exit_code.should eq(1)
    expected_index = GitOracle.run(root, "ls-files", "-s").stdout
    expected_files = Dir.children(root).reject { |name| name == ".git" }.to_h do |name|
      {name, {File.read(File.join(root, name)), File.info(File.join(root, name)).permissions.includes?(File::Permissions::OwnerExecute)}}
    end
    GitOracle.run(root, "merge", "--abort")
    repo.merge("topic", author: SIGNATURE, committer: SIGNATURE, message: "merge")
    GitOracle.run(root, "ls-files", "-s").stdout.should eq(expected_index)
    actual_files = Dir.children(root).reject { |name| name == ".git" }.to_h do |name|
      {name, {File.read(File.join(root, name)), File.info(File.join(root, name)).permissions.includes?(File::Permissions::OwnerExecute)}}
    end
    actual_files.should eq(expected_files)
    GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
    repo.merge.abort
    GitOracle.run(root, "ls-files", "-s").stdout.should eq(original_index)
    GitOracle.run(root, "status", "--porcelain").stdout.should eq("")
  end
end

describe "Git divergent rename source bounds" do
  ["sha1", "sha256"].each do |format|
    ["marker-budget", "invalid-encoding"].each do |scenario|
      it "refuses #{format} #{scenario} before mutable publication" do
        GitOracle.with_repo(format: format) do |root|
          repo = Git::Repository.new(root)
          prefix = scenario == "invalid-encoding" ? String.new(Bytes[0xff]) : ""
          text = prefix + (0...32).map { |i| "word#{i.to_s.rjust(2, '0')} stable content " }.join + "\n"
          base = AdversarialMergeSources.commit(repo, {"old" => text}, [] of String, 1234567890_i64)
          ours_data = text.sub("word02", "left02")
          ours = AdversarialMergeSources.commit(repo, {"ours" => ours_data}, [base], 1234567891_i64)
          theirs = AdversarialMergeSources.commit(repo, {"theirs" => text.sub("word02", "rght02")}, [base], 1234567892_i64)
          GitOracle.run(root, "update-ref", "refs/heads/main", ours)
          GitOracle.run(root, "update-ref", "refs/heads/topic", theirs)
          GitOracle.run(root, "reset", "--hard", "main")
          before_index = File.read(File.join(root, ".git/index"))
          expected = scenario == "marker-budget" ? /source conflict marker budget/ : /source conflict text encoding/
          expect_raises(Git::Error, expected) do
            repo.merge("topic", author: AdversarialMergeSources::SIGNATURE,
              committer: AdversarialMergeSources::SIGNATURE, message: "merge", max_object_bytes: 1024)
          end
          GitOracle.run(root, "rev-parse", "HEAD").stdout.strip.should eq(ours)
          File.read(File.join(root, ".git/index")).should eq(before_index)
          File.read(File.join(root, "ours")).should eq(ours_data)
          File.exists?(File.join(root, "theirs")).should be_false
          File.exists?(File.join(root, ".git/MERGE_HEAD")).should be_false
          File.exists?(File.join(root, ".git/CRYSTAL_MERGE_PATHS")).should be_false
          File.exists?(File.join(root, ".git/index.lock")).should be_false
        end
      end
    end
  end
end

describe "Git adversarial rename source composition" do
  ["sha1", "sha256"].each do |format|
    it "ignores #{format} symlink ancestor encoding when both sides become regular text" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        base = AdversarialMergeSources.commit(repo, {"f" => String.new(Bytes[0xff])}, [] of String,
          1234567890_i64, symlink: "f")
        ours = AdversarialMergeSources.commit(repo, {"f" => "ours\n"}, [base], 1234567891_i64)
        theirs = AdversarialMergeSources.commit(repo, {"f" => "theirs\n"}, [base], 1234567892_i64)
        AdversarialMergeSources.compare(root, repo, ours, theirs)
      end
    end

    ["crosswired", "ordinary-overlap", "rename-delete"].each do |scenario|
      [false, true].each do |reverse|
        it "preserves #{format} #{scenario} reverse=#{reverse} contributions" do
          GitOracle.with_repo(format: format) do |root|
            repo = Git::Repository.new(root)
            a, b = AdversarialMergeSources::ALPHA, AdversarialMergeSources::BRAVO
            base = AdversarialMergeSources.commit(repo, {"a" => a, "b" => b}, [] of String, 1234567890_i64)
            left_files = {"x" => a, "y" => b}
            right_files = case scenario
                          when "crosswired"       then {"y" => a, "x" => b}
                          when "ordinary-overlap" then {"a" => a, "x" => b}
                          else                         {"y" => a}
                          end
            left_files, right_files = right_files, left_files if reverse
            ours = AdversarialMergeSources.commit(repo, left_files, [base], 1234567891_i64)
            theirs = AdversarialMergeSources.commit(repo, right_files, [base], 1234567892_i64)
            AdversarialMergeSources.compare(root, repo, ours, theirs)
          end
        end
      end
    end

    it "preserves #{format} conflicts through crosswired recursive bases" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        a, b = AdversarialMergeSources::ALPHA, AdversarialMergeSources::BRAVO
        base = AdversarialMergeSources.commit(repo, {"a" => a, "b" => b}, [] of String, 1234567890_i64)
        left = AdversarialMergeSources.commit(repo, {"x" => a, "y" => b}, [base], 1234567891_i64)
        right = AdversarialMergeSources.commit(repo, {"x" => b, "y" => a}, [base], 1234567892_i64)
        ours = AdversarialMergeSources.commit(repo, {"x" => a, "y" => b}, [left, right], 1234567893_i64)
        theirs = AdversarialMergeSources.commit(repo, {"x" => b, "y" => b}, [right, left], 1234567894_i64)
        AdversarialMergeSources.compare(root, repo, ours, theirs)
      end
    end

    it "preserves #{format} original binary sources in divergent recursive bases" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        original = "\0" + "A" * 319
        left_data = "\0" + "B" * 63 + "A" * 256
        right_data = "\0" + "C" * 63 + "A" * 256
        base = AdversarialMergeSources.commit(repo, {"old" => original}, [] of String, 1234567890_i64)
        left = AdversarialMergeSources.commit(repo, {"x" => left_data}, [base], 1234567891_i64)
        right = AdversarialMergeSources.commit(repo, {"y" => right_data}, [base], 1234567892_i64)
        ours = AdversarialMergeSources.commit(repo, {"x" => left_data, "y" => right_data}, [left, right], 1234567893_i64)
        theirs = AdversarialMergeSources.commit(repo, {"x" => right_data, "y" => right_data}, [right, left], 1234567894_i64)
        AdversarialMergeSources.compare(root, repo, ours, theirs)
      end
    end

    it "retains #{format} structural stages when crosswired sources merge equally" do
      GitOracle.with_repo(format: format) do |root|
        repo = Git::Repository.new(root)
        text = (0...20).map { |i| "line #{i}: stable content\n" }.join
        a, b, shared = text + "a unique\n", text + "b unique\n", text + "shared\n"
        base = AdversarialMergeSources.commit(repo, {"a" => a, "b" => b}, [] of String, 1234567890_i64)
        ours = AdversarialMergeSources.commit(repo, {"x" => shared, "y" => b}, [base], 1234567891_i64)
        theirs = AdversarialMergeSources.commit(repo, {"x" => shared, "y" => a}, [base], 1234567892_i64)
        AdversarialMergeSources.compare(root, repo, ours, theirs)
      end
    end

    ["ordinary-binary-base", "divergent-binary-base", "divergent-ours-executable", "divergent-theirs-executable"].each do |scenario|
      it "preserves #{format} #{scenario} classification and source modes" do
        GitOracle.with_repo(format: format) do |root|
          repo = Git::Repository.new(root)
          binary = scenario.ends_with?("binary-base")
          text = (0...20).map { |i| "word#{i.to_s.rjust(2, '0')} stable content " + (binary ? "\n" : "") }.join
          text += "\n" unless binary
          base = AdversarialMergeSources.commit(repo, {"old" => (binary ? "\0" : "") + text}, [] of String, 1234567890_i64)
          ours_path, theirs_path = scenario == "ordinary-binary-base" ? {"old", "old"} : {"ours", "theirs"}
          ours = AdversarialMergeSources.commit(repo, {ours_path => text.sub("word02", "left02")}, [base], 1234567891_i64,
            scenario == "divergent-ours-executable" ? ours_path : "")
          theirs = AdversarialMergeSources.commit(repo, {theirs_path => text.sub("word02", "rght02")}, [base], 1234567892_i64,
            scenario == "divergent-theirs-executable" ? theirs_path : "")
          AdversarialMergeSources.compare(root, repo, ours, theirs)
        end
      end
    end
  end
end
