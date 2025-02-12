// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Bridge Interface
 * @author Nebula Labs LLC
 * @custom:security-contact security@nebula-labs.xyz
 */

interface IBRIDGE {
    /**
     * @dev Token Struct.
     * @param name name
     * @param symbol symbol
     * @param tokenAddress address
     */
    struct Token {
        string name;
        string symbol;
        address tokenAddress;
    }

    /**
     * @dev Chain Struct.
     * @param name string
     * @param chainId chainId
     */
    struct Chain {
        string name;
        uint256 chainId;
    }

    /**
     * @dev Transaction Struct.
     * @param sender address
     * @param receiver address
     * @param token address
     * @param amount bridged
     * @param time of transaction
     * @param destChainId destination chainId
     */
    struct Transaction {
        address sender;
        address receiver;
        address token;
        uint256 amount;
        uint256 time;
        uint256 destChainId;
    }

    /**
     * @dev Initialized Event.
     * @param src sender address
     */
    event Initialized(address indexed src);

    /**
     * @dev Upgrade Event.
     * @param src sender address
     * @param implementation address
     */
    event Upgrade(address indexed src, address indexed implementation);

    /**
     * @dev ListToken Event.
     * @param token address
     */
    event ListToken(address indexed token);

    /**
     * @dev DelistToken Event.
     * @param token address
     */
    event DelistToken(address indexed token);

    /**
     * @dev AddChain Event.
     * @param chainId number
     */
    event AddChain(uint256 chainId);

    /**
     * @dev RemoveChain Event.
     * @param chainId number
     */
    event RemoveChain(uint256 chainId);

    /**
     * @dev Bridged Event.
     * @param transactionID, id of transaction
     * @param from, address of sender
     * @param to, address of receiver
     * @param token, address of token
     * @param amount, amount bridged
     * @param destChainId, destination chain id
     */
    event Bridged(
        uint256 transactionID,
        address indexed from,
        address indexed to,
        address indexed token,
        uint256 amount,
        uint256 destChainId
    );

    /**
     * @dev Custom Error.
     * @param msg error desription
     */
    error CustomError(string msg);

    /**
     * @dev Pause contract.
     */
    function pause() external;

    /**
     * @dev Unpause contract.
     */
    function unpause() external;

    /**
     * @dev List Token.
     * @param name name
     * @param symbol symbol
     * @param token address
     */
    function listToken(string calldata name, string calldata symbol, address token) external;

    /**
     * @dev Delist Token.
     * @param token address
     */
    function removeToken(address token) external;

    /**
     * @dev Bridge tokens.
     * @param token, address of token
     * @param to, address of receiver
     * @param amount, amount bridged
     * @param destChainId, destination chain id
     * @return transactionId
     */
    function bridgeTokens(address token, address to, uint256 amount, uint256 destChainId) external returns (uint256);

    /**
     * @dev Add supported chain.
     * @param name chain name
     * @param chainId chain ID
     */
    function addChain(string calldata name, uint256 chainId) external;

    /**
     * @dev Remove supported chain.
     * @param chainId chain ID
     */
    function removeChain(uint256 chainId) external;

    /**
     * @dev Getter for the last transactionId.
     * @return last transaction Id
     */
    function transactionId() external view returns (uint256);

    /**
     * @dev Getter for the number of transaction on a particular chain.
     * @param chainId, number
     * @return chain transaction count
     */
    function chainCount(uint256 chainId) external view returns (uint256);

    /**
     * @dev Getter for the Token object.
     * @param token address
     * @return Token info object
     */
    function getToken(address token) external view returns (Token memory);

    /**
     * @dev Getter for the supported token listings.
     * @return array of listed token addresses
     */
    function getListings() external view returns (address[] memory array);

    /**
     * @dev Getter returns true if token is listed.
     * @param token address
     * @return boolean value
     */
    function isListed(address token) external view returns (bool);

    /**
     * @dev Getter returns listed token count.
     * @return number of listed tokens
     */
    function getListedCount() external view returns (uint256);

    /**
     * @dev Getter returns chain transaction count.
     * @param chainId chain ID
     * @return number of transaction for this chain
     */
    function getChainTransactionCount(uint256 chainId) external view returns (uint256);

    /**
     * @dev Getter returns transaction object.
     * @param tranId address
     * @return Transaction struct (IBRIDGE)
     */
    function getTransaction(uint256 tranId) external view returns (Transaction memory);

    /**
     * @dev Getter returns Chain object.
     * @param chainId chain ID
     * @return Chain struct (IBRIDGE)
     */
    function getChain(uint256 chainId) external view returns (Chain memory);

    /**
     * @dev Getter returns Token object.
     * @param token address
     * @return Token struct (IBRIDGE)
     */
    function getTokenInfo(address token) external view returns (Token memory);

    /**
     * @dev Getter for the UUPS version.
     * @return upgrade version (1,2,3)
     */
    function version() external view returns (uint32);
}
