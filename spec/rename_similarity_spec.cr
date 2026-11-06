require "spec"
require "../src/git"

describe Git::TreeDiff::Similarity do
  it "scores empty content as zero" do
    blobs = {"empty" => "", "line" => "line\n"}
    similarity = Git::TreeDiff::Similarity.new { |oid| blobs[oid] }
    similarity.score("empty", "empty").should eq(0)
    similarity.score("empty", "line").should eq(0)
    similarity.score("line", "empty").should eq(0)
  end

  it "counts shared repeated spans against the larger byte size" do
    blobs = {"left" => "same\n" * 3 + "left\n", "right" => "same\n" * 2 + "right\n"}
    similarity = Git::TreeDiff::Similarity.new { |oid| blobs[oid] }
    similarity.score("left", "right").should eq(30_000)
    similarity.score("right", "left").should eq(30_000)
    similarity.score("left", "left").should eq(60_000)
  end

  it "keeps an exact fifty percent match and rejects an excessive size difference" do
    blobs = {"source" => "a" * 64, "half" => "a" * 64 + "b" * 64, "below" => "a" * 64 + "b" * 65}
    similarity = Git::TreeDiff::Similarity.new { |oid| blobs[oid] }
    similarity.score("source", "half").should eq(30_000)
    similarity.score("source", "below").should eq(0)
  end

  it "normalizes text CRLF spans while retaining the raw byte denominator" do
    blobs = {"crlf" => "a\r\nb\r\n", "lf" => "a\nb\n"}
    similarity = Git::TreeDiff::Similarity.new { |oid| blobs[oid] }
    similarity.score("crlf", "lf").should eq(40_000)
    similarity.score("crlf", "crlf").should eq(40_000)
  end

  it "preserves binary CRLF and hashes arbitrary bytes" do
    blobs = {"crlf" => "\0a\r\n", "lf" => "\0a\n", "bytes" => String.new(Bytes[0xff, 0x80, 0x0a])}
    similarity = Git::TreeDiff::Similarity.new { |oid| blobs[oid] }
    similarity.score("crlf", "lf").should eq(0)
    similarity.score("crlf", "crlf").should eq(60_000)
    similarity.score("bytes", "bytes").should eq(60_000)
  end

  it "limits binary detection to the first eight thousand bytes" do
    prefix = "a\n" * 4000
    blobs = {"crlf" => prefix + "\0x\r\n", "lf" => prefix + "\0x\n"}
    similarity = Git::TreeDiff::Similarity.new { |oid| blobs[oid] }
    similarity.score("crlf", "lf").should eq(59_992)
  end

  it "reads each object only once across scores and both sides" do
    reads = [] of String
    blobs = {"left" => "same\n", "right" => "same\n"}
    similarity = Git::TreeDiff::Similarity.new do |oid|
      raise "object read twice" if reads.includes?(oid)
      reads << oid
      blobs[oid]
    end
    similarity.score("left", "right").should eq(60_000)
    similarity.score("right", "left").should eq(60_000)
    similarity.score("left", "left").should eq(60_000)
    reads.should eq(["left", "right"])
  end

  it "polls cancellation during a large signature scan" do
    polls = 0
    check = -> do
      polls += 1
      raise Git::Error.new("cancelled similarity scan") if polls == 3
      nil
    end
    similarity = Git::TreeDiff::Similarity.new(check) { |_oid| "a" * 100_000 }
    expect_raises(Git::Error, /cancelled similarity scan/) { similarity.score("left", "right") }
  end

  it "leaves failed reads uncached and preserves the reader error" do
    reads = 0
    similarity = Git::TreeDiff::Similarity.new do |_oid|
      reads += 1
      raise Git::Error.new("reader limit") if reads == 1
      "line\n"
    end
    expect_raises(Git::Error, /reader limit/) { similarity.score("one", "one") }
    similarity.score("one", "one").should eq(60_000)
    reads.should eq(2)
  end
end
