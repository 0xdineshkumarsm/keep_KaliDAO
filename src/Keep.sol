// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ERC1155TokenReceiver, KeepToken} from "./KeepToken.sol";
import {Multicallable} from "./utils/Multicallable.sol";
import {ERC1271} from "./utils/ERC1271.sol";

/// @title Keep
/// @notice EIP-712 multi-signature wallet with ERC1155 interface.
/// @author KaliCo LLC (https://github.com/kalidao/multi-sig/blob/main/src/Keep.sol)

enum Operation {
    call,
    delegatecall,
    create,
    create2
}

struct Call {
    Operation op;
    address to;
    uint256 value;
    bytes data;
}

struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

contract Keep is ERC1155TokenReceiver, KeepToken, Multicallable {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    /// @dev Emitted when Keep executes call.
    event Executed(Operation op, address indexed to, uint256 value, bytes data);

    /// @dev Emitted when Keep creates contract.
    event ContractCreated(
        Operation op,
        address indexed creation,
        uint256 value
    );

    /// @dev Emitted when quorum threshold is updated.
    event QuorumSet(address indexed operator, uint256 threshold);

    /// -----------------------------------------------------------------------
    /// Custom Errors
    /// -----------------------------------------------------------------------

    /// @dev Throws if `initialize()` is called more than once.
    error AlreadyInit();

    /// @dev Throws if quorum exceeds `totalSupply(EXECUTE_ID)`.
    error QuorumOverSupply();

    /// @dev Throws if `execute()` doesn't complete operation.
    error ExecuteFailed();

    /// -----------------------------------------------------------------------
    /// Keep Storage/Logic
    /// -----------------------------------------------------------------------

    /// @dev Master ID key permission.
    uint256 internal immutable MASTER_ID = uint32(uint160(address(this)));

    /// @dev Default metadata fetcher for `uri()`.
    Keep internal immutable _uriFetcher;

    /// @dev Record of states verifying `execute()`.
    uint96 public nonce;

    /// @dev EXECUTE_ID threshold to `execute()`.
    uint96 public quorum;

    /// @dev Internal ID metadata mapping.
    mapping(uint256 => string) internal _uris;

    /// @dev ID metadata fetcher.
    /// @param id ID to fetch from.
    /// @return tokenURI Metadata.
    function uri(uint256 id)
        public
        view
        virtual
        override
        returns (string memory tokenURI)
    {
        tokenURI = _uris[id];

        if (bytes(tokenURI).length != 0) return tokenURI;
        else return _uriFetcher.uri(id);
    }

    /// @dev The immutable name of this Keep.
    /// @return Name string.
    function name() public pure virtual returns (string memory) {
        return string(abi.encodePacked(_computeArgUint256(2)));
    }

    /// @dev Access control check for ID key balance holders.
    function _authorized() internal view virtual returns (bool) {
        if (_masterKeyHolder() || balanceOf[msg.sender][uint32(msg.sig)] != 0)
            return true;
        else revert NotAuthorized();
    }

    /// @dev Master access control check.
    /// Initalizes with `address(this)` having implicit permission
    /// without writing to storage by checking `totalSupply()` is zero.
    /// Otherwise, this permission can be set to additional accounts,
    /// including retaining `address(this)`, via `mint()`.
    function _masterKeyHolder() internal view virtual returns (bool) {
        return
            (msg.sender == address(this) && totalSupply[MASTER_ID] == 0) ||
            balanceOf[msg.sender][MASTER_ID] != 0;
    }

    /// -----------------------------------------------------------------------
    /// ERC165 Logic
    /// -----------------------------------------------------------------------

    /// @dev ERC165 interface detection.
    /// @param interfaceId ID to check.
    /// @return Fetch detection success.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return
            interfaceId == this.onERC721Received.selector || // ERC165 Interface ID for ERC721TokenReceiver.
            interfaceId == type(ERC1155TokenReceiver).interfaceId || // ERC165 Interface ID for ERC1155TokenReceiver.
            super.supportsInterface(interfaceId); // ERC165 Interface IDs for ERC1155.
    }

    /// -----------------------------------------------------------------------
    /// ERC721 Receiver Logic
    /// -----------------------------------------------------------------------

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) public payable virtual returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// -----------------------------------------------------------------------
    /// Initialization Logic
    /// -----------------------------------------------------------------------

    /// @notice Create Keep template.
    /// @param uriFetcher Metadata default.
    constructor(Keep uriFetcher) payable {
        _uriFetcher = uriFetcher;
    }

    /// @notice Initialize Keep configuration.
    /// @param calls Initial Keep operations.
    /// @param signers Initial signer set.
    /// @param threshold Initial quorum.
    function initialize(
        Call[] calldata calls,
        address[] calldata signers,
        uint256 threshold
    ) public payable virtual {
        if (quorum != 0) revert AlreadyInit();

        assembly {
            if iszero(threshold) {
                revert(0, 0)
            }
        }

        if (threshold > signers.length) revert QuorumOverSupply();

        if (calls.length != 0) {
            for (uint256 i; i < calls.length; ) {
                _execute(
                    calls[i].op,
                    calls[i].to,
                    calls[i].value,
                    calls[i].data
                );

                // An array can't have a total length
                // larger than the max uint256 value.
                unchecked {
                    ++i;
                }
            }
        }

        address previous;
        address signer;
        uint256 supply;

        for (uint256 i; i < signers.length; ) {
            signer = signers[i];

            // Prevent zero and duplicate signers.
            if (previous >= signer) revert InvalidSig();

            previous = signer;

            // Won't realistically overflow.
            unchecked {
                ++balanceOf[signer][EXECUTE_ID];
                ++supply;
                ++i;
            }

            // We don't call `_moveDelegates()` to save deployment gas.
            emit TransferSingle(msg.sender, address(0), signer, EXECUTE_ID, 1);
        }

        quorum = uint96(threshold);

        totalSupply[EXECUTE_ID] = supply;

        KeepToken._initialize();
    }

    /// -----------------------------------------------------------------------
    /// Execution Logic
    /// -----------------------------------------------------------------------

    /// @notice Execute operation from Keep with signatures.
    /// @param op Enum operation to execute.
    /// @param to Address to send operation to.
    /// @param value Amount of ETH to send in operation.
    /// @param data Payload to send in operation.
    /// @param sigs Array of Keep signatures sorted in ascending order by addresses.
    /// @dev Make sure signatures are sorted in ascending order - otherwise verification will fail.
    /// @return success Fetch whether operation succeeded.
    function execute(
        Operation op,
        address to,
        uint256 value,
        bytes calldata data,
        Signature[] calldata sigs
    ) public payable virtual returns (bool success) {
        // Begin signature validation with payload hash.
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256(
                            "Execute(Operation op,address to,uint256 value,bytes data,uint256 nonce)"
                        ),
                        op,
                        to,
                        value,
                        data,
                        nonce
                    )
                )
            )
        );

        // Start from zero in loop to ensure ascending addresses.
        address previous;
        // Validation is length of quorum threshold.
        uint256 threshold = quorum;

        for (uint256 i; i < threshold; ) {
            address signer = ecrecover(digest, sigs[i].v, sigs[i].r, sigs[i].s);

            // Check contract signature with EIP-1271.
            if (signer.code.length != 0) {
                if (
                    ERC1271(signer).isValidSignature(
                        digest,
                        abi.encodePacked(sigs[i].r, sigs[i].s, sigs[i].v)
                    ) != ERC1271.isValidSignature.selector
                ) revert InvalidSig();
            }

            // Check EXECUTE_ID balance.
            if (balanceOf[signer][EXECUTE_ID] == 0) revert InvalidSig();
            // Check duplicates.
            if (previous >= signer) revert InvalidSig();

            // Memo signer for next iteration until quorum.
            previous = signer;

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
            }
        }

        success = _execute(op, to, value, data);
    }

    /// @notice Execute operations from Keep with `execute()` or as key holder.
    /// @param calls Keep operations as arrays of `op, to, value, data`.
    /// @return successes Fetches whether operations succeeded.
    function multiExecute(Call[] calldata calls)
        public
        payable
        virtual
        returns (bool[] memory successes)
    {
        _authorized();

        successes = new bool[](calls.length);

        for (uint256 i; i < calls.length; ) {
            successes[i] = _execute(
                calls[i].op,
                calls[i].to,
                calls[i].value,
                calls[i].data
            );

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
            }
        }
    }

    function _execute(
        Operation op,
        address to,
        uint256 value,
        bytes memory data
    ) internal virtual returns (bool success) {
        // Won't realistically overflow.
        unchecked {
            ++nonce;
        }

        if (op == Operation.call) {
            assembly {
                success := call(
                    gas(),
                    to,
                    value,
                    add(data, 0x20),
                    mload(data),
                    0,
                    0
                )
            }

            if (!success) revert ExecuteFailed();

            emit Executed(op, to, value, data);
        } else if (op == Operation.delegatecall) {
            assembly {
                success := delegatecall(
                    gas(),
                    to,
                    add(data, 0x20),
                    mload(data),
                    0,
                    0
                )
            }

            if (!success) revert ExecuteFailed();

            emit Executed(op, to, value, data);
        } else if (op == Operation.create) {
            address creation;

            assembly {
                creation := create(value, add(data, 0x20), mload(data))
            }

            if (creation == address(0)) revert ExecuteFailed();

            emit ContractCreated(op, creation, value);
        } else {
            address creation;
            bytes32 salt = bytes32(uint256(nonce));

            assembly {
                creation := create2(value, add(0x20, data), mload(data), salt)
            }

            if (creation == address(0)) revert ExecuteFailed();

            emit ContractCreated(op, creation, value);
        }
    }

    /// -----------------------------------------------------------------------
    /// Mint/Burn Logic
    /// -----------------------------------------------------------------------

    /// @notice ID minter.
    /// @param to Recipient of mint.
    /// @param id ID to mint.
    /// @param amount ID balance to mint.
    /// @param data Optional data payload.
    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) public payable virtual {
        _authorized();

        _mint(to, id, amount, data);
    }

    /// @notice ID burner.
    /// @param from Account to burn from.
    /// @param id ID to burn.
    /// @param amount Balance to burn.
    function burn(
        address from,
        uint256 id,
        uint256 amount
    ) public payable virtual {
        if (
            msg.sender != from &&
            !isApprovedForAll[from][msg.sender] &&
            !_authorized()
        ) revert NotAuthorized();

        _burn(from, id, amount);

        if (id == EXECUTE_ID)
            if (quorum > totalSupply[EXECUTE_ID]) revert QuorumOverSupply();
    }

    /// -----------------------------------------------------------------------
    /// Threshold Setting Logic
    /// -----------------------------------------------------------------------

    /// @notice Update Keep quorum threshold.
    /// @param threshold Signature threshold for `execute()`.
    function setQuorum(uint96 threshold) public payable virtual {
        _authorized();

        assembly {
            if iszero(threshold) {
                revert(0, 0)
            }
        }

        // note: Make sure signers don't concentrate ID keys,
        // as this could cause issues in reaching quorum.
        if (threshold > totalSupply[EXECUTE_ID]) revert QuorumOverSupply();

        quorum = threshold;

        emit QuorumSet(msg.sender, threshold);
    }

    /// -----------------------------------------------------------------------
    /// ID Setting Logic
    /// -----------------------------------------------------------------------

    /// @notice ID transferability setter.
    /// @param id ID to set transferability for.
    /// @param transferability Transferability setting.
    function setTransferability(uint256 id, bool transferability)
        public
        payable
        virtual
    {
        _authorized();

        _setTransferability(id, transferability);
    }

    /// @notice ID transfer permission toggle.
    /// @param id ID to set permission for.
    /// @param set Permission setting.
    /// @dev This sets account-based ID restriction globally.
    function setPermission(uint256 id, bool set) public payable virtual {
        _authorized();

        _setPermission(id, set);
    }

    /// @notice ID transfer permission setting.
    /// @param to Account to set permission for.
    /// @param id ID to set permission for.
    /// @param set Permission setting.
    /// @dev This sets account-based ID restriction specifically.
    function setUserPermission(
        address to,
        uint256 id,
        bool set
    ) public payable virtual {
        _authorized();

        _setUserPermission(to, id, set);
    }

    /// @notice ID metadata setter.
    /// @param id ID to set metadata for.
    /// @param tokenURI Metadata setting.
    function setURI(uint256 id, string calldata tokenURI)
        public
        payable
        virtual
    {
        _authorized();

        _uris[id] = tokenURI;

        emit URI(tokenURI, id);
    }
}
