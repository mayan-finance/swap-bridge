struct Order {
	Status status;
	uint64 amountIn;
	uint16 destChainId;
}

struct OrderParams {
	uint8 payloadType;
	bytes32 trader;
	bytes32 destAddr;
	uint16 destChainId;
	bytes32 referrerAddr;
	bytes32 tokenOut;
	uint64 minAmountOut;
	uint64 gasDrop;
	uint64 cancelFee;
	uint64 refundFee;
	uint64 deadline;
	uint8 referrerBps;
	uint8 auctionMode;
	bytes32 random;
}

struct ExtraParams {
	uint16 srcChainId;
	bytes32 tokenIn;
	uint8 protocolBps;
	bytes32 customPayloadHash;
}

struct PermitParams {
	uint256 value;
	uint256 deadline;
	uint8 v;
	bytes32 r;
	bytes32 s;
}

struct Key {
	uint8 payloadType;
	bytes32 trader;
	uint16 srcChainId;
	bytes32 tokenIn;
	bytes32 destAddr;
	uint16 destChainId;
	bytes32 tokenOut;
	uint64 minAmountOut;
	uint64 gasDrop;
	uint64 cancelFee;
	uint64 refundFee;
	uint64 deadline;
	bytes32 referrerAddr;
	uint8 referrerBps;
	uint8 protocolBps;
	uint8 auctionMode;
	bytes32 random;
	bytes32 customPayloadHash;
}

struct PaymentParams {
	uint8 payloadType;
	bytes32 orderHash;
	uint64 promisedAmount;
	uint64 minAmountOut;
	address destAddr;
	address tokenOut;
	uint64 gasDrop;
	bool batch;
}

enum Status {
	CREATED,
	FULFILLED,
	SETTLED,
	UNLOCKED,
	CANCELED,
	REFUNDED
}

enum Action {
	NONE,
	FULFILL,
	UNLOCK,
	REFUND,
	BATCH_UNLOCK,
	COMPRESSED_UNLOCK
}

enum AuctionMode {
	NONE,
	BYPASS,
	ENGLISH
}

struct UnlockMsg {
	uint8 action;
	bytes32 orderHash;
	uint16 srcChainId;
	bytes32 tokenIn;
	bytes32	referrerAddr;
	uint8 referrerBps;
	uint8 protocolBps;		
	bytes32 unlockReceiver;
	bytes32 driver;
	uint64 fulfillTime;
}
uint constant UNLOCK_MSG_SIZE = 172;	// excluding the action field

struct RefundMsg {
	uint8 action;
	bytes32 orderHash;
	uint16 srcChainId;
	bytes32 tokenIn;
	bytes32 trader;
	bytes32 canceler;
	uint64 cancelFee;
	uint64 refundFee;
}

struct FulfillMsg {
	uint8 action;
	bytes32 orderHash;
	bytes32 driver;
	uint64 promisedAmount;
	uint16 penaltyPeriod;
}

struct TransferParams {
	address from;
	uint256 validAfter;
	uint256 validBefore;
}

struct SolverParams {
	bytes32 recipient;
	bytes32 driver;
}

struct RescueMsg {
	uint8 orderStatus;
	bytes32 orderHash;
	address token;
	uint64 amount;
}