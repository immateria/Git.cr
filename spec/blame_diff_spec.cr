require "spec"
require "../src/git"

describe Git::TextDiff do
  it "maps unchanged byte lines around insertions and replacements" do
    Git::TextDiff.equal_spans("first\nold\nlast\n".to_slice,
      "added\nfirst\nnew\nlast\n".to_slice).should eq([{0, 1, 1}, {2, 3, 1}])
  end

  it "retains the final newline when matching lines" do
    Git::TextDiff.equal_spans("first\ntail".to_slice,
      "first\ntail\n".to_slice).should eq([{0, 0, 1}])
    Git::TextDiff.equal_spans("tail".to_slice, "tail".to_slice).should eq([{0, 0, 1}])
    Git::TextDiff.equal_spans(Bytes.empty, Bytes.empty).should be_empty
  end

  it "uses xdiff correspondence for repeated lines" do
    Git::TextDiff.equal_spans("a\na\nb\n".to_slice,
      "a\nb\na\n".to_slice).should eq([{0, 0, 1}, {2, 1, 1}])
  end

  it "compares binary and invalid UTF-8 lines as bytes" do
    Git::TextDiff.equal_spans(Bytes[0, 255, 10, 1, 10],
      Bytes[2, 10, 0, 255, 10, 1, 10]).should eq([{0, 1, 2}])
  end

  it "bounds the combined line count including identical content" do
    expect_raises(Git::Error, /line budget/) do
      Git::TextDiff.equal_spans("a\nb\n".to_slice, "a\nb\n".to_slice, max_lines: 3)
    end
    expect_raises(ArgumentError) do
      Git::TextDiff.equal_spans(Bytes.empty, Bytes.empty, max_lines: -1)
    end
  end

  it "rejects exhausted work while allowing the same diff with a generous budget" do
    old_data = (0...300).map { |i| "#{i}\n" }.join.to_slice
    new_data = (0...300).to_a.reverse.map { |i| "#{i}\n" }.join.to_slice
    expect_raises(Git::Error, /work budget/) do
      Git::TextDiff.equal_spans(old_data, new_data, max_work: 1_i64)
    end
    expect_raises(Git::Error, /work budget/) do
      Git::TextDiff.equal_spans(old_data, new_data, max_work: 10_000_i64)
    end
    Git::TextDiff.equal_spans(old_data, new_data, max_work: 1_000_000_i64).should_not be_empty
    expect_raises(ArgumentError) do
      Git::TextDiff.equal_spans(Bytes.empty, Bytes.empty, max_work: -1_i64)
    end
  end

  it "charges work for long identical content" do
    data = ("same\n" * 5000).to_slice
    expect_raises(Git::Error, /work budget/) do
      Git::TextDiff.equal_spans(data, data, max_work: 10_i64)
    end
  end

  it "shares a cumulative work budget across comparisons" do
    work = Git::TextDiff::Work.new(1000_i64)
    Git::TextDiff.equal_spans("a\n".to_slice, "a\n".to_slice, work: work).should eq([{0, 0, 1}])
    work.used.should be > 0
    expect_raises(Git::Error, /work budget/) do
      1000.times do
        Git::TextDiff.equal_spans("a\n".to_slice, "a\n".to_slice, work: work)
      end
    end
    expect_raises(ArgumentError) { Git::TextDiff::Work.new(-1_i64) }
  end

  it "polls the cancellation callback carried by shared work" do
    cancel = -> { raise "cancelled shared diff" }
    work = Git::TextDiff::Work.new(1000_i64, cancel)
    expect_raises(Exception, "cancelled shared diff") do
      Git::TextDiff.equal_spans("a\n".to_slice, "a\n".to_slice, work: work)
    end
  end

  it "polls cancellation during long byte scans" do
    calls = 0
    cancel = -> do
      calls += 1
      raise "cancelled equal spans" if calls == 3
    end
    expect_raises(Exception, "cancelled equal spans") do
      Git::TextDiff.equal_spans(("x" * 100_000).to_slice, ("y" * 100_000).to_slice, check: cancel)
    end
  end
end
