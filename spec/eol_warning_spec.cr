require "spec"
require "../src/git"
require "./support/git_oracle"

describe "public EOL staging warnings" do
  ["sha1", "sha256"].each do |format|
    ["true", "warn"].each do |safecrlf|
      it "limits #{format} safecrlf=#{safecrlf} checks to selected staging paths" do
        GitOracle.with_repo(format: format) do |root|
          repository = Git::Repository.new(root)
          repository.stage_blob(".gitignore", "ignored\n")
          File.write(File.join(root, ".gitignore"), "ignored\n")
          File.write(File.join(root, "file"), "new")
          config = repository.config(command_values: [
            {"core.autocrlf", "true"}, {"core.safecrlf", safecrlf},
          ])
          index_path = File.join(root, ".git", "index")
          before = File.read(index_path)
          GitOracle.run(root, "-c", "core.autocrlf=true", "-c", "core.safecrlf=#{safecrlf}", "add", "file").success?.should be_true
          File.write(index_path, before)
          messages = [] of String
          warning = ->(message : String) { messages << message; nil }
          repository.stage(["file"], config: config, warning: warning).should eq(["file"])
          messages.should be_empty
          repository.index_entries.find { |entry| entry.path == ".gitignore" }.not_nil!.oid.should eq(
            Git::ObjectId.digest("blob", "ignored\n", repository.object_format))
          # The same ignore file must still be checked when selected,
          # including when its canonical content already matches the index.
          if safecrlf == "true"
            expect_raises(Git::Error, /LF.+CRLF.+\.gitignore/) do
              repository.stage([".gitignore"], config: config, warning: warning)
            end
          else
            repository.stage([".gitignore"], config: config, warning: warning).should be_empty
            messages.size.should eq(1)
            messages[0].should match(/LF.+CRLF.+\.gitignore/)
          end
        end
      end
    end

    ["stage_file", "stage"].each do |operation|
      it "keeps edits made by a #{format} #{operation} warning callback visible" do
        GitOracle.with_repo(format: format) do |root|
          repository = Git::Repository.new(root)
          path = File.join(root, "file.txt")
          File.write(path, "before\r\n")
          File.touch(path, Time.unix(1_600_000_000))
          config = repository.config(command_values: [
            {"core.autocrlf", "input"}, {"core.safecrlf", "warn"},
          ])
          warning = ->(_message : String) do
            File.write(path, "after!\n")
            File.touch(path, Time.unix(1_600_000_000))
            nil
          end
          if operation == "stage_file"
            repository.stage_file("file.txt", config: config, warning: warning)
          else
            repository.stage(["file.txt"], config: config, warning: warning)
          end
          indexed = repository.index_entries.find { |entry| entry.path == "file.txt" }.not_nil!
          repository.read_object(indexed.oid).data.should eq("before\n")
          File.read(path).should eq("after!\n")
          repository.working_changes(config: config).map(&.path).should eq(["file.txt"])
          repository.working_file("file.txt", config: config).not_nil!.new_text.should eq("after!\n")
          repository.diff(config: config).empty?.should be_false
          GitOracle.run(root, "-c", "core.autocrlf=input", "diff", "--exit-code", check: false).success?.should be_false
        end
      end

      it "reports unsafe #{format} conversion through #{operation} without changing its return type" do
        GitOracle.with_repo(format: format) do |root|
          repository = Git::Repository.new(root)
          File.write(File.join(root, "file.txt"), "one\r\n")
          config = repository.config(command_values: [
            {"core.autocrlf", "input"}, {"core.safecrlf", "warn"},
          ])
          messages = [] of String
          warning = ->(message : String) { messages << message; nil }
          oid = Git::ObjectId.digest("blob", "one\n", repository.object_format)
          if operation == "stage_file"
            repository.stage_file("file.txt", config: config, warning: warning).should eq(oid)
          else
            repository.stage(["file.txt"], config: config, warning: warning).should eq(["file.txt"])
          end
          messages.size.should eq(1)
          messages[0].should match(/CRLF.+LF.+file\.txt/)
          repository.index_entries.find { |entry| entry.path == "file.txt" }.not_nil!.oid.should eq(oid)
          File.read(File.join(root, "file.txt")).should eq("one\r\n")
        end
      end
    end

    it "reports a tracked #{format} path once despite batch staging's repeated reads" do
      GitOracle.with_repo(format: format) do |root|
        repository = Git::Repository.new(root)
        repository.stage_blob("tracked.txt", "old\n")
        File.write(File.join(root, "tracked.txt"), "new\n")
        File.write(File.join(root, "new.txt"), "new\n")
        config = repository.config(command_values: [
          {"core.autocrlf", "true"}, {"core.safecrlf", "warn"},
        ])
        messages = [] of String
        warning = ->(message : String) { messages << message; nil }
        repository.stage(config: config, warning: warning).should eq(["new.txt", "tracked.txt"])
        messages.size.should eq(2)
        messages.count { |message| message.matches?(/LF.+CRLF.+new\.txt/) }.should eq(1)
        messages.count { |message| message.matches?(/LF.+CRLF.+tracked\.txt/) }.should eq(1)
      end
    end
  end

  ["stage_file", "stage"].each do |operation|
    it "propagates a failing #{operation} warning callback before index publication" do
      GitOracle.with_repo do |root|
        repository = Git::Repository.new(root)
        repository.stage_blob("kept", "kept\n")
        index = File.read(File.join(root, ".git", "index"))
        File.write(File.join(root, "file.txt"), "one\r\n")
        config = repository.config(command_values: [
          {"core.autocrlf", "input"}, {"core.safecrlf", "warn"},
        ])
        warning = ->(_message : String) : Nil { raise "stop on warning" }
        expect_raises(Exception, "stop on warning") do
          if operation == "stage_file"
            repository.stage_file("file.txt", config: config, warning: warning)
          else
            repository.stage(["file.txt"], config: config, warning: warning)
          end
        end
        File.read(File.join(root, ".git", "index")).should eq(index)
        File.read(File.join(root, "file.txt")).should eq("one\r\n")
      end
    end
  end
end
