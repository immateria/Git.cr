require "spec"
require "file_utils"
require "../src/git"
require "./support/git_oracle"

# Real repositories have identities, branch names, ref names and patterns
# outside ASCII. Byte offsets and character offsets differ there, so each
# parser that slices text is exercised with multibyte input.

private UMLAUT = Git::Signature.new("Jöhännes Müller", "jm@example.invalid", 1_700_000_900, 120)

private def commit_as(root : String, name : String, text : String, time : Int64,
                      author : String = "Jöhännes Müller", committer_time : Int64? = nil) : String
  File.write(File.join(root, name), text)
  GitOracle.run(root, "add", name)
  env = {"GIT_AUTHOR_NAME" => author, "GIT_COMMITTER_NAME" => author,
         "GIT_AUTHOR_DATE" => "#{time} +0200", "GIT_COMMITTER_DATE" => "#{committer_time || time} +0200"}
  GitOracle.run(root, "commit", "-qm", "Ünïcode #{name}\n\nBödy für #{name}.", extra_env: env)
  GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
end

describe "non-ASCII text in real repositories" do
  it "NA-01 orders history by the committer time of non-ASCII identities" do
    GitOracle.with_repo do |root|
      commit_as(root, "a", "a\n", 1_700_000_000)
      GitOracle.run(root, "checkout", "-qb", "side")
      commit_as(root, "b", "b\n", 1_700_000_100, committer_time: 1_700_000_500)
      GitOracle.run(root, "checkout", "-q", "main")
      commit_as(root, "c", "c\n", 1_700_000_200, author: "Plain Ascii")
      GitOracle.run(root, "merge", "-q", "--no-edit", "side", extra_env: {"GIT_COMMITTER_DATE" => "1700000600 +0000", "GIT_AUTHOR_DATE" => "1700000600 +0000"})
      repo = Git::Repository.new(root)
      repo.rev_list(["HEAD"]).should eq(GitOracle.run(root, "rev-list", "HEAD").stdout.split)
      {Git::History::Order::Default => nil, Git::History::Order::Date => "--date-order",
       Git::History::Order::Topological => "--topo-order"}.each do |order, flag|
        repo.log(["HEAD"], order: order).commits.map(&.oid).should eq(GitOracle.run_args(root, ["rev-list", flag, "HEAD"].compact).stdout.split)
      end
      repo.rev_list(["main..side"]).should eq(GitOracle.run(root, "rev-list", "main..side").stdout.split)
    end
  end

  it "NA-02 reads subjects and headers of commits by non-ASCII authors" do
    GitOracle.with_repo do |root|
      oid = commit_as(root, "a", "a\n", 1_700_000_000)
      commit = Git::Repository.new(root).read_commit(oid)
      commit.subject.should eq("Ünïcode a")
      commit.author.should eq("Jöhännes Müller <oracle@example.invalid> 1700000000 +0200")
      commit.committer.should eq("Jöhännes Müller <oracle@example.invalid> 1700000000 +0200")
    end
  end

  it "NA-03 keeps messages intact when amending and cherry-picking" do
    GitOracle.with_repo do |root|
      commit_as(root, "a", "a\n", 1_700_000_000)
      GitOracle.run(root, "checkout", "-qb", "side")
      picked = commit_as(root, "b", "b\n", 1_700_000_100)
      GitOracle.run(root, "checkout", "-q", "main")
      repo = Git::Repository.new(root)
      amended = repo.amend(committer: UMLAUT)
      message = GitOracle.run(root, "log", "-1", "--format=%B", amended).stdout
      message.should eq("Ünïcode a\n\nBödy für a.\n\n")
      repo.cherry_pick(picked, committer: UMLAUT)
      GitOracle.run(root, "log", "-1", "--format=%B").stdout.should eq("Ünïcode b\n\nBödy für b.\n\n")
      GitOracle.run(root, "log", "-1", "--format=%an|%cn").stdout.strip.should eq("Jöhännes Müller|Jöhännes Müller")
    end
  end

  it "NA-04 reads and writes configuration for non-ASCII branch names" do
    GitOracle.with_repo do |root|
      commit_as(root, "a", "a\n", 1_700_000_000)
      repo = Git::Repository.new(root)
      repo.branches.create("fëature")
      repo.branches.set_upstream("fëature", Git::Branch::Upstream.new("origin", "refs/heads/fëature"))
      GitOracle.run(root, "config", "branch.fëature.merge").stdout.should eq("refs/heads/fëature\n")
      GitOracle.run(root, "config", "branch.fëature.remote").stdout.should eq("origin\n")
      repo.branches.upstream("fëature").should eq(Git::Branch::Upstream.new("origin", "refs/heads/fëature"))
      repo.rev_list(["main..fëature"]).should be_empty
    end
  end

  it "NA-05 matches non-ASCII ignore patterns and byte-level ? / [...] wildmatch like Git" do
    GitOracle.with_repo do |root|
      File.write(File.join(root, ".gitignore"), "ü*.txt\nä?.md\ncaf?.log\ncaf??.tmp\ncaf[!a-z].dat\nnaïve/\n")
      ["ünter.txt", "über.txt", "äx.md", "ax.md", "cafe.log", "café.log", "cafe.tmp", "café.tmp",
       "caf1.dat", "café.dat", "keep.txt", "naïve/inside"].each do |name|
        path = File.join(root, name)
        Dir.mkdir_p(File.dirname(path))
        File.write(path, "x\n")
      end
      repo = Git::Repository.new(root)
      native = repo.working_changes.map(&.path).sort
      expected = GitOracle.run(root, "-c", "core.quotePath=false", "status", "--porcelain=v1", "-uall").stdout.lines.map { |line| line.byte_slice(3) }.sort
      native.should eq(expected)
      # Single `?` and `[!a-z]` match 1 byte, so 2-byte `é` is not matched by `caf?.log` or `caf[!a-z].dat`,
      # whereas `caf??.tmp` matches 2-byte `é` in `café.tmp`.
      native.should eq([".gitignore", "ax.md", "cafe.tmp", "café.dat", "café.log", "keep.txt"])
    end
  end

  it "NA-06 parses ref advertisements with non-ASCII ref names" do
    oid = "1" * 40
    io = IO::Memory.new
    Git::Protocol::PktLine.write(io, "#{oid} refs/heads/fëature\0report-status symref=HEAD:refs/heads/fëature\n")
    Git::Protocol::PktLine.write(io, "#{oid} refs/tags/ünïcode\n")
    io << "0000"
    advertisement = Git::Protocol::Advertisement.parse(io.to_slice)
    advertisement.refs.map(&.name).should eq(["refs/heads/fëature", "refs/tags/ünïcode"])
    advertisement.capability?("report-status").should be_true
  end

  # Older commits often carry Latin-1 bytes: Git keeps undeclared bytes and
  # shows text in a declared encoding as UTF-8.
  it "NA-07 reads and logs commits that are not UTF-8" do
    GitOracle.with_repo do |root|
      commit_as(root, "a", "a\n", 1_700_000_000)
      tree = GitOracle.run(root, "rev-parse", "HEAD^{tree}").stdout.strip
      head = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      latin1 = String.new(Bytes[0x4d, 0xfc, 0x6c, 0x6c, 0x65, 0x72]) # "Müller" in Latin-1
      raw = "tree #{tree}\nparent #{head}\nauthor #{latin1} <m@example.invalid> 1700000100 +0000\n" \
            "committer #{latin1} <m@example.invalid> 1700000100 +0000\n\nGr#{String.new(Bytes[0xfc])}\u{df}e #{latin1}\n"
      undeclared = GitOracle.run(root, "hash-object", "-t", "commit", "-w", "--stdin", input: raw).stdout.strip
      declared_raw = "tree #{tree}\nparent #{undeclared}\nauthor #{latin1} <m@example.invalid> 1700000200 +0000\n" \
                     "committer #{latin1} <m@example.invalid> 1700000200 +0000\nencoding ISO-8859-1\n\nSch#{String.new(Bytes[0xf6])}n\n"
      declared = GitOracle.run(root, "hash-object", "-t", "commit", "-w", "--stdin", input: declared_raw).stdout.strip
      GitOracle.run(root, "update-ref", "refs/heads/main", declared)
      repo = Git::Repository.new(root)
      commits = repo.log(["HEAD"]).commits
      commits.map(&.oid).should eq(GitOracle.run(root, "rev-list", "HEAD").stdout.split)
      commits[0].subject.should eq("Schön")
      commits[0].author.should eq("Müller <m@example.invalid> 1700000200 +0000")
      commits[1].author.to_slice.should eq("#{latin1} <m@example.invalid> 1700000100 +0000".to_slice)
      commits[1].subject.valid_encoding?.should be_false
    end
  end

  it "NA-08 cherry-picks a Latin-1 commit without changing its bytes" do
    GitOracle.with_repo do |root|
      commit_as(root, "a", "a\n", 1_700_000_000)
      GitOracle.run(root, "checkout", "-qb", "side")
      File.write(File.join(root, "b"), "b\n")
      GitOracle.run(root, "add", "b")
      latin1 = String.new(Bytes[0x4d, 0xfc, 0x6c, 0x6c, 0x65, 0x72])
      GitOracle.run(root, "-c", "i18n.commitEncoding=binary", "commit", "-qm", "Fix by #{latin1}",
        extra_env: {"GIT_AUTHOR_NAME" => latin1, "GIT_AUTHOR_DATE" => "1700000100 +0000"})
      picked = GitOracle.run(root, "rev-parse", "HEAD").stdout.strip
      GitOracle.run(root, "checkout", "-q", "main")
      repo = Git::Repository.new(root)
      repo.cherry_pick(picked, committer: UMLAUT)
      original = GitOracle.run(root, "cat-file", "commit", picked).stdout
      copied = GitOracle.run(root, "cat-file", "commit", "HEAD").stdout
      copied.split("\n\n", 2)[1].to_slice.should eq(original.split("\n\n", 2)[1].to_slice)
      copied.lines.find!(&.starts_with?("author ")).to_slice.should eq(original.lines.find!(&.starts_with?("author ")).to_slice)
    end
  end

  it "NA-09 honours core.excludesFile before info/exclude and .gitignore" do
    GitOracle.with_repo do |root|
      global_excludes = File.join(File.dirname(root), "global.ignore")
      File.write(global_excludes, "*.global\n!keep.global\n")
      GitOracle.run(root, "config", "core.excludesFile", global_excludes)
      File.write(File.join(root, "drop.global"), "x\n")
      File.write(File.join(root, "keep.global"), "y\n")
      repo = Git::Repository.new(root)
      changes = repo.working_changes(config: repo.config)
      changes.map(&.path).should eq(["keep.global"])
    end
  end
end
