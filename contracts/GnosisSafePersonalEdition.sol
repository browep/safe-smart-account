pragma solidity 0.4.24;
import "./GnosisSafe.sol";
import "./MasterCopy.sol";
import "./SignatureDecoder.sol";
import "./SecuredTokenTransfer.sol";

contract ISingatureValidator {
    /**
    * @dev Should return whether the signature provided is valid for the provided data
    * @param _data Arbitrary length data signed on the behalf of address(this)
    * @param _signature Signature byte array associated with _data
    *
    * MUST return a bool upon valid or invalid signature with corresponding _data
    * MUST take (bytes, bytes) as arguments
    */ 
    function isValidSignature(
        bytes _data, 
        bytes _signature)
        public
        view 
        returns (bool isValid); 
}

/// @title Gnosis Safe Personal Edition - A multisignature wallet with support for confirmations using signed messages based on ERC191.
/// @author Stefan George - <stefan@gnosis.pm>
/// @author Richard Meissner - <richard@gnosis.pm>
/// @author Ricardo Guilherme Schmidt - (Status Research & Development GmbH) - Gas Token Payment
contract GnosisSafePersonalEdition is MasterCopy, GnosisSafe, SignatureDecoder, SecuredTokenTransfer, ISingatureValidator {

    string public constant NAME = "Gnosis Safe Personal Edition";
    string public constant VERSION = "0.0.1";
    //keccak256(
    //    "PersonalSafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 dataGas,uint256 gasPrice,address gasToken,uint256 nonce)"
    //);
    bytes32 public constant SAFE_TX_TYPEHASH = 0x068c3b33cc9bff6dde08209527b62abfb1d4ed576706e2078229623d72374b5b;
    //keccak256(
    //    "PersonalSafeMessage(bytes message)"
    //);
    bytes32 public constant SAFE_MSG_TYPEHASH = 0x1dfa4160f82a6e0d96a1aabb41071e8f04e57366990e6134b0092beba479c1f1;
    
    event ExecutionFailed(bytes32 txHash);

    uint256 public nonce;
    mapping(bytes32 => uint256) signedMessage;

    /// @dev Allows to execute a Safe transaction confirmed by required number of owners and then pays the account that submitted the transaction.
    ///      Note: The fees are always transfered, even if the user transaction fails. 
    /// @param to Destination address of Safe transaction.
    /// @param value Ether value of Safe transaction.
    /// @param data Data payload of Safe transaction.
    /// @param operation Operation type of Safe transaction.
    /// @param safeTxGas Gas that should be used for the Safe transaction.
    /// @param dataGas Gas costs for data used to trigger the safe transaction and to pay the payment transfer
    /// @param gasPrice Gas price that should be used for the payment calculation.
    /// @param gasToken Token address (or 0 if ETH) that is used for the payment.
    /// @param signatures Packed signature data ({bytes32 r}{bytes32 s}{uint8 v})
    function execTransactionAndPaySubmitter(
        address to, 
        uint256 value, 
        bytes data, 
        Enum.Operation operation, 
        uint256 safeTxGas,
        uint256 dataGas,
        uint256 gasPrice,
        address gasToken,
        bytes signatures
    )
        public
        returns (bool success)
    {
        uint256 startGas = gasleft();
        bytes memory txHashData = encodeTransactionData(to, value, data, operation, safeTxGas, dataGas, gasPrice, gasToken, nonce);
        require(checkSignatures(keccak256(txHashData), txHashData, signatures), "Invalid signatures provided");
        // Increase nonce and execute transaction.
        nonce++;
        require(gasleft() >= safeTxGas, "Not enough gas to execute safe transaction");
        // If no safeTxGas has been set and the gasPrice is 0 we assume that all available gas can be used
        uint256 gasLimit;
        if (safeTxGas == 0 && gasPrice == 0) {
            gasLimit = gasleft();
        } else {
            gasLimit = safeTxGas;
        }
        success = execute(to, value, data, operation, gasLimit);
        if (!success) {
            emit ExecutionFailed(keccak256(txHashData));
        }
        
        // We transfer the calculated tx costs to the tx.origin to avoid sending it to intermediate contracts that have made calls
        if (gasPrice > 0) {
            uint256 gasCosts = (startGas - gasleft()) + dataGas;
            uint256 amount = gasCosts * gasPrice;
            if (gasToken == address(0)) {
                 // solium-disable-next-line security/no-tx-origin,security/no-send
                require(tx.origin.send(amount), "Could not pay gas costs with ether");
            } else {
                 // solium-disable-next-line security/no-tx-origin
                require(transferToken(gasToken, tx.origin, amount), "Could not pay gas costs with token");
            }
        }
    }

    function checkSignatures(bytes32 messageHash, bytes message, bytes signatures)
        internal
        view
        returns (bool)
    {
        // There cannot be an owner with address 0.
        address lastOwner = address(0);
        address currentOwner;
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 i;
        for (i = 0; i < threshold; i++) {
            (v, r, s) = signatureSplit(signatures, i);
            // If v is zero then it is a contract signature
            if (v == 0) {
                // When handling contract signatures the address of the contract is encoded into r
                currentOwner = address(r);
                bytes memory contractSignature;
                // solium-disable-next-line security/no-inline-assembly
                assembly {
                    // The signature data for contract signatures is appended to the concatenated signatures and the offset is stored in s
                    contractSignature := add(add(signatures, s), 0x20)
                }
                if (!ISingatureValidator(currentOwner).isValidSignature(message, contractSignature)) {
                    return false;
                }
            } else {
                // Use ecrecover with the messageHash for EOA signatures
                currentOwner = ecrecover(messageHash, v, r, s);
            }
            if (currentOwner <= lastOwner || owners[currentOwner] == 0) {
                return false;
            }
            lastOwner = currentOwner;
        }
        return true;
    }

    /// @dev Allows to estimate a Safe transaction. 
    ///      This method is only meant for estimation purpose, therfore two different protection mechanism against execution in a transaction have been made:
    ///      1.) The method can only be called from the safe itself
    ///      2.) The response is returned with a revert
    ///      When estimating set `from` to the address of the safe.
    ///      Since the `estimateGas` function includes refunds, call this method to get an estimated of the costs that are deducted from the safe with `execTransactionAndPaySubmitter`
    /// @param to Destination address of Safe transaction.
    /// @param value Ether value of Safe transaction.
    /// @param data Data payload of Safe transaction.
    /// @param operation Operation type of Safe transaction.
    /// @return Estimate without refunds and overhead fees (base transaction and payload data gas costs).
    function requiredTxGas(address to, uint256 value, bytes data, Enum.Operation operation)
        public
        authorized
        returns (uint256)
    {
        uint256 startGas = gasleft();
        // We don't provide an error message here, as we use it to return the estimate
        // solium-disable-next-line error-reason
        require(execute(to, value, data, operation, gasleft()));
        uint256 requiredGas = startGas - gasleft();
        // Convert response to string and return via error message
        revert(string(abi.encodePacked(requiredGas)));
    }

    /**
    * @dev Marks a message as signed
    * @param _data Arbitrary length data that should be marked as signed on the behalf of address(this)
    */ 
    function signMessage(bytes _data) 
        public
        authorized
    {
        signedMessage[getMessageHash(_data)] = 1;
    }

    /**
    * @dev Should return whether the signature provided is valid for the provided data
    * @param _data Arbitrary length data signed on the behalf of address(this)
    * @param _signature Signature byte array associated with _data
    * @return a bool upon valid or invalid signature with corresponding _data
    */ 
    function isValidSignature(bytes _data, bytes _signature)
        public
        view 
        returns (bool isValid)
    {
        bytes32 messageHash = getMessageHash(_data);
        if (_signature.length == 0) {
            isValid = signedMessage[messageHash] != 0;
        } else {
            isValid = checkSignatures(messageHash, _data, _signature);
        }
    }

    /// @dev Returns hash of a message that can be signed by owners.
    /// @param message Message that should be hashed
    /// @return Message hash.
    function getMessageHash(
        bytes message
    )
        public
        view
        returns (bytes32)
    {
        bytes32 safeMessageHash = keccak256(
            abi.encode(SAFE_MSG_TYPEHASH, keccak256(message))
        );
        return keccak256(
            abi.encodePacked(byte(0x19), byte(1), domainSeperator, safeMessageHash)
        );
    }

    /// @dev Returns the bytes that are hashed to be signed by owners.
    /// @param to Destination address.
    /// @param value Ether value.
    /// @param data Data payload.
    /// @param operation Operation type.
    /// @param safeTxGas Fas that should be used for the safe transaction.
    /// @param dataGas Gas costs for data used to trigger the safe transaction.
    /// @param gasPrice Maximum gas price that should be used for this transaction.
    /// @param gasToken Token address (or 0 if ETH) that is used for the payment.
    /// @param _nonce Transaction nonce.
    /// @return Transaction hash bytes.
    function encodeTransactionData(
        address to, 
        uint256 value, 
        bytes data, 
        Enum.Operation operation, 
        uint256 safeTxGas, 
        uint256 dataGas, 
        uint256 gasPrice, 
        address gasToken,
        uint256 _nonce
    )
        public
        view
        returns (bytes)
    {
        bytes32 safeTxHash = keccak256(
            abi.encode(SAFE_TX_TYPEHASH, to, value, keccak256(data), operation, safeTxGas, dataGas, gasPrice, gasToken, _nonce)
        );
        return abi.encodePacked(byte(0x19), byte(1), domainSeperator, safeTxHash);
    }

    /// @dev Returns hash to be signed by owners.
    /// @param to Destination address.
    /// @param value Ether value.
    /// @param data Data payload.
    /// @param operation Operation type.
    /// @param safeTxGas Fas that should be used for the safe transaction.
    /// @param dataGas Gas costs for data used to trigger the safe transaction.
    /// @param gasPrice Maximum gas price that should be used for this transaction.
    /// @param gasToken Token address (or 0 if ETH) that is used for the payment.
    /// @param _nonce Transaction nonce.
    /// @return Transaction hash.
    function getTransactionHash(
        address to, 
        uint256 value, 
        bytes data, 
        Enum.Operation operation, 
        uint256 safeTxGas, 
        uint256 dataGas, 
        uint256 gasPrice, 
        address gasToken,
        uint256 _nonce
    )
        public
        view
        returns (bytes32)
    {
        return keccak256(encodeTransactionData(to, value, data, operation, safeTxGas, dataGas, gasPrice, gasToken, _nonce));
    }
}
