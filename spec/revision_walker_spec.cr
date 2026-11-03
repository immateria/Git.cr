require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

private def commit_at(root : String, message : String, time : Int64) : String
  GitOracle.run(root, "add", "-A")
  GitOracle.run(root, "commit", "-qm", message, "--allow-empty",
    extra_env: {"GIT_COMMITTER_DATE" => "#{time} +0000", "GIT_AUTHOR_DATE" => "#{time} +0000"})
  GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
end

# main and topic diverge, merge, and diverge again; a second root history
# lives on "orphan". One commit has a committer date older than its parent.
private def branching_history(root : String) : Nil
  time = 1_700_000_000_i64
  Dir.mkdir_p(File.join(root, "src", "lib"))
  File.write(File.join(root, "README"), "readme\n")
  File.write(File.join(root, "src", "main.cr"), "puts 1\n")
  commit_at(root, "root", time)
  6.times do |i|
    File.write(File.join(root, "src", "lib", "part#{i % 2}.cr"), "# part #{i}\n" * (i + 2))
    commit_at(root, "main #{i}", time += 100)
  end
  GitOracle.run(root, "checkout", "-q", "-b", "topic", "HEAD~3")
  3.times do |i|
    File.write(File.join(root, "topic-#{i}.txt"), "topic #{i}\n")
    File.write(File.join(root, "src", "main.cr"), "puts #{i + 10}\n")
    commit_at(root, "topic #{i}", time += 100)
  end
  # Clock skew: this commit claims to be older than its parent.
  File.write(File.join(root, "skewed.txt"), "skew\n")
  commit_at(root, "skewed", time - 10_000)
  GitOracle.run(root, "checkout", "-q", "main")
  GitOracle.run(root, "merge", "-q", "--no-ff", "-m", "merge topic", "topic",
    extra_env: {"GIT_COMMITTER_DATE" => "#{time += 100} +0000", "GIT_AUTHOR_DATE" => "#{time} +0000"})
  File.write(File.join(root, "after.txt"), "after merge\n")
  commit_at(root, "after merge", time += 100)
  GitOracle.run(root, "tag", "-a", "v1", "-m", "v1\n", "HEAD~1")
  GitOracle.run(root, "checkout", "-q", "--orphan", "orphan")
  GitOracle.run(root, "rm", "-rqf", ".")
  File.write(File.join(root, "README"), "readme\n")
  File.write(File.join(root, "other.txt"), "other\n")
  commit_at(root, "orphan root", time += 100)
  GitOracle.run(root, "checkout", "-q", "main")
end

private def rev_list(root : String, args : Array(String)) : Array(String)
  GitOracle.run_args(root, args).stdout.lines
end

private def resolve(root : String, rev : String) : String
  GitOracle.run(root, "rev-parse", rev).stdout.strip
end

describe "Git::History::RevisionWalker" do
  ["sha1", "sha256"].each do |format|
    it "REACH-O01 matches git rev-list --objects for tips, exclusions, tags and trees (#{format})" do
      GitOracle.with_repo(format: format) do |root|
        branching_history(root)
        repo = Git::Repository.new(root)
        cases = [
          {["main"], [] of String},
          {["main"], ["topic"]},
          {["topic"], ["main~3"]},
          {["main", "orphan"], ["main~2"]},
          {["orphan"], ["main"]},
          {["main"], ["main"]},
          {["v1"], ["main~4"]},
          {["main^{tree}"], [] of String},
        ]
        cases.each do |wants, haves|
          args = ["rev-list", "--objects"] + wants + (haves.empty? ? [] of String : ["--not"] + haves)
          expected = rev_list(root, args).map { |line| line.starts_with?(resolve(root, "v1")) ? resolve(root, "v1") : line }.to_set
          items = repo.reachable_objects(wants.map { |rev| resolve(root, rev) }, haves.map { |rev| resolve(root, rev) })
          actual = items.map { |item| item.type.commit? || item.type.tag? ? item.oid : "#{item.oid} #{item.path}" }.to_set
          {wants, haves, actual}.should eq({wants, haves, expected})
          items.map(&.oid).uniq.size.should eq(items.size)
          items.each do |item|
            GitOracle.run(root, "cat-file", "-t", item.oid).stdout.strip.should eq(item.type.to_s)
          end
        end
        commits = Git::History::RevisionWalker.new(repo).commits([resolve(root, "main")], [resolve(root, "topic~2")])
        commits.should eq(rev_list(root, ["rev-list", "main", "--not", "topic~2"]))
      end
    end
  end

  it "REACH-O02 answers ancestry like git merge-base --is-ancestor, including clock skew" do
    GitOracle.with_repo do |root|
      branching_history(root)
      repo = Git::Repository.new(root)
      revs = ["main", "main~1", "main~2", "main~5", "topic", "topic~1", "topic~3", "orphan", "v1^{commit}"]
      revs.each do |left|
        revs.each do |right|
          expected = GitOracle.run(root, "merge-base", "--is-ancestor", left, right, check: false).exit_code == 0
          {left, right, repo.ancestor?(resolve(root, left), resolve(root, right))}.should eq({left, right, expected})
        end
      end
    end
  end
end
