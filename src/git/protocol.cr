module Git
  # Git's wire protocol: pkt-line framing, side-band multiplexing and the
  # version 0/1 and version 2 conversations of upload-pack and
  # receive-pack, with a client and a server for each.
  module Protocol
    AGENT = "git.cr/#{Git::VERSION}"

    # The remote side reported an error ("ERR ..." or side-band channel 3).
    class RemoteFailure < Git::Error
    end

    # The remote side spoke something this implementation does not accept.
    class Violation < Git::Error
    end
  end
end

require "./protocol/pkt_line"
require "./protocol/sideband"
require "./protocol/advertisement"
require "./protocol/server"
require "./protocol/upload_pack/server"
require "./protocol/upload_pack/negotiator"
require "./protocol/upload_pack/client"
require "./protocol/receive_pack/server"
require "./protocol/receive_pack/client"
