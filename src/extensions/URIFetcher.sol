// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Owned} from "./utils/Owned.sol";
import {URIRemoteFetcher} from "./URIRemoteFetcher.sol";

/// @notice Open-ended metadata fetcher for ERC1155 URI.
/// @author z0r0z.eth
contract URIFetcher is Owned {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event URIRemoteFetcherSet(
        address indexed user, 
        URIRemoteFetcher indexed uriRemoteFetcher
    );

    /// -----------------------------------------------------------------------
    /// URI Remote Storage
    /// -----------------------------------------------------------------------

    URIRemoteFetcher public uriRemoteFetcher;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(address _owner, URIRemoteFetcher _uriRemoteFetcher) payable Owned(_owner) {
        uriRemoteFetcher = _uriRemoteFetcher;
    }

    /// -----------------------------------------------------------------------
    /// URI Logic
    /// -----------------------------------------------------------------------

    function uri(uint256 id) public view virtual returns (string memory) {
        return uriRemoteFetcher.fetchURI(msg.sender, id);
    }

    function setURIRemote(URIRemoteFetcher _uriRemoteFetcher) public payable onlyOwner virtual {
        uriRemoteFetcher = _uriRemoteFetcher;

        emit URIRemoteFetcherSet(msg.sender, _uriRemoteFetcher);
    }
}
