require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

describe "P25 native Git revision and merge-base" do
  ["sha1", "sha256"].each do |format|
    it "P25-O01 resolves #{format} parent selectors, names and peeled tags" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-qb", "side")
        File.write(File.join(root, "a"), "side\n")
        GitOracle.run(root, "commit", "-qam", "side")
        side = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        GitOracle.run(root, "checkout", "-q", "main")
        File.write(File.join(root, "a"), "main\n")
        GitOracle.run(root, "commit", "-qam", "main")
        main = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        # Use an explicit synthetic two-parent commit so test does not depend on conflict resolution.
        tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
        merge = GitOracle.run(root, "commit-tree", tree, "-p", main, "-p", side, input: "merge\n").stdout.strip
        GitOracle.run(root, "update-ref", "refs/heads/main", merge)
        GitOracle.run(root, "tag", "-am", "release", "v1")
        repo = Git::Repository.new(root)
        expressions = ["HEAD^", "HEAD^1", "HEAD^2", "HEAD~1", "HEAD~2", "HEAD~1^", "main~2", "v1^0", "v1^{commit}", "HEAD^0", "HEAD~0", "HEAD^2~1"]
        expressions.each do |expression|
          expected = GitOracle.run(root, "rev-parse", "--verify", expression).stdout.strip
          Git::History.resolve_commit(repo, expression, 8_388_608, nil).should eq(expected)
        end
        Git::History.resolve_commit(repo, "HEAD^2", 8_388_608, nil).should eq(side)
        Git::History.resolve_commit(repo, "HEAD~2", 8_388_608, nil).should eq(base)
        Git::History.resolve_commit(repo, "HEAD^1", 8_388_608, nil).should eq(main)
        expect_raises(Git::Error) { Git::History.resolve_commit(repo, "HEAD^3", 8_388_608, nil) }
        expect_raises(Git::Error) { Git::History.resolve_commit(repo, "HEAD~20", 8_388_608, nil) }
        expect_raises(Git::Error) { Git::History.resolve_commit(repo, "HEAD^{tree}", 8_388_608, nil) }
      end
    end

    it "P25-O02 finds all #{format} best common ancestors on criss-cross DAG" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        base = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
        a = GitOracle.run(root, "commit-tree", tree, "-p", base, input: "a\n").stdout.strip
        b = GitOracle.run(root, "commit-tree", tree, "-p", base, input: "b\n").stdout.strip
        left = GitOracle.run(root, "commit-tree", tree, "-p", a, "-p", b, input: "left\n").stdout.strip
        right = GitOracle.run(root, "commit-tree", tree, "-p", b, "-p", a, input: "right\n").stdout.strip
        GitOracle.run(root, "update-ref", "refs/heads/left", left)
        GitOracle.run(root, "update-ref", "refs/heads/right", right)
        repo = Git::Repository.new(root)
        native = repo.merge_bases("left", "right")
        native.to_set.should eq([a, b].to_set)
        GitOracle.run(root, "merge-base", "--all", "left", "right").stdout.lines.map(&.strip).to_set.should eq(native.to_set)
        repo.merge_bases("left", "left").should eq([left])
        repo.merge_bases("left", "main").should eq([base])
        expect_raises(Git::Error, /node budget/) { repo.merge_bases("left", "right", max_nodes: 2) }
      end
    end

    it "P25-O03 handles unrelated #{format} commit roots without inventing a base" do
      GitOracle.with_repo(format: format) do |root|
        File.write(File.join(root, "a"), "base\n")
        GitOracle.run(root, "add", ".")
        GitOracle.run(root, "commit", "-qm", "base")
        old = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
        tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
        unrelated = GitOracle.run(root, "commit-tree", tree, input: "unrelated\n").stdout.strip
        repo = Git::Repository.new(root)
        repo.merge_bases(old, unrelated).should be_empty
        GitOracle.run(root, "merge-base", "--all", old, unrelated, check: false).success?.should be_false
      end
    end
  end
end
