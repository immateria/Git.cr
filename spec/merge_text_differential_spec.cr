require "spec"
require "../src/git"
require "./support/git_oracle"

# Permanent small differential grid for the shared text combiner used by
# merge, rebase, cherry-pick, revert and stash. Keep this independent of the
# large optional fuzz corpus; it is small enough for routine native-git CI.
describe "bounded text merge differential grid" do
  it "F1 rejects every unsafe clean result in 324 unique-line edit pairs" do
    GitOracle.with_repo do |root|
      original = (0...6).map { |i| "line-#{i}\n" }
      base_path = File.join(root, "base")
      ours_path = File.join(root, "ours")
      theirs_path = File.join(root, "theirs")
      File.write(base_path, original.join)
      modes = {"replace", "delete", "insert"}
      clean_both = 0
      oracle_conflicts = 0
      conservative_conflicts = 0
      {0, 1, 2, 3, 4, 5}.each do |left_pos|
        {0, 1, 2, 3, 4, 5}.each do |right_pos|
          modes.each do |left_mode|
            modes.each do |right_mode|
              left = original.dup
              right = original.dup
              case left_mode
              when "replace" then left[left_pos] = "OURS\n"
              when "delete"  then left.delete_at(left_pos)
              when "insert"  then left.insert(left_pos, "OURS\n")
              end
              case right_mode
              when "replace" then right[right_pos] = "THEIRS\n"
              when "delete"  then right.delete_at(right_pos)
              when "insert"  then right.insert(right_pos, "THEIRS\n")
              end
              File.write(ours_path, left.join)
              File.write(theirs_path, right.join)
              oracle = GitOracle.run(root, "merge-file", "-p", ours_path, base_path, theirs_path, check: false)
              oracle.exit_code.should be <= 1
              native = Git::Merge::Text.merge(original.join, left.join, right.join)
              if oracle.exit_code == 1
                oracle_conflicts += 1
                native.should be_nil, "unsafe clean result: #{left_pos} #{left_mode} / #{right_pos} #{right_mode}"
              elsif native
                clean_both += 1
                native.should eq(oracle.stdout), "changed bytes: #{left_pos} #{left_mode} / #{right_pos} #{right_mode}"
              else
                conservative_conflicts += 1
              end
            end
          end
        end
      end
      (clean_both + oracle_conflicts + conservative_conflicts).should eq(324)
    end
  end
end
