/* PREAMBLE
    This programme is a Smart Contract for the auctioning of NFT tokens, using the Vickrey Auction method(sealed-bid, second price),
    The programme is made to ensure maximum security, mainly using commitment schemes to keep data private and prevent attacks(more in the report).

    Flow of the programme:
    1. The owner of the NFT calls an auction using the createAuction function, declaring their NFT contract and token's ID.
       In the call, they declare the NFT contract and token ID, while specifying the auction's reserve price, bidding duration, and reveal duration.
       The function creates an ID for the specific auction and returns it, so the seller is aware of the auction ID
    2. The bidder uses the getCurrentAuctionId function to get access to the most current(and likely ongoing) auction
    3. The bidder uses the getAuction function with the auction ID to access information about the auction they want to bid in, including the reserve price.
    4. The user decides their bid value and creates their hash commitment off the chain, using the generateCommitment function. 
    5. The bidder uses the commitBid function to send their committed bid for the specific auction, while sending their deposit that should be higher than the bid.
    6. The bidder uses the revealBid function to reveal their bid, inputting their bid value and nonce (ONLY AFTER BIDDING ENDS).
       The programme will use inputted data to verify bidder information, and set the highest and second-highest bidders.
    7. Anyone can call the finaliseAuction function ONCE REVEALING IS COMPLETE.
       The NFT is transferred from the seller to the highest bidder at the price of the second highest bid.
    8. The seller receives their funds for the NFT by calling the withdrawSeller function.
    9. The winner receives their refund (deposit-price of NFT) and the losers obtain their bids by calling the withdraw function.




    Code is indexed into numeric indexes to ensure comprehension.
*/

//0: ENSURE CORRECT SOLIDITY VERSION IS USED, INTERFACE INCLUDED FOR ERC-721

//SPDX-License-Identifier-MIT
pragma solidity ^0.8.0;

//Interface ERC721 
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract VickreyAuction {
    
    //1: STRUCTS, NECESSARY VARIABLES
    
    //1.1 Struct for auctions
    struct auction { 
        address seller; 
        address nftContract; 
        uint tokenId; 
        uint reservePrice; 
        uint biddingEnd; 
        uint revealEnd; 
        address highestBidder; 
        uint highestBid; 
        uint secondHighestBid;
        uint finalPrice; 
        bool finalised; 
        bool paymentWithdrawn;
    }

    //1.2 Struct for bids
    struct bid {
        bytes32 commitment; 
        uint deposit; 
        bool revealed; 
        uint bidAmount;
        bool withdrawn;
    }

    //1.3 Auction counter (Used for Auction ID)
    uint public auctionCounter; 

    //2. STORAGE MAPPING 
    mapping(uint => auction) public auctions;
    mapping(uint => mapping(address => bid)) public bids; 
    mapping(uint256 => address[]) private bidders; 

    
    //3. EVENTS

    //3.1 Logs relevant data when an auction is created
    event auctionCreated (
        uint indexed auctionId, 
        address indexed seller,
        address nftContract,
        uint tokenId,
        uint reservePrice,
        uint biddingEnd,
        uint revealEnd
    ); 

    //3.2 Logs relevant data when a bid is committed
    event bidCommitted (
        uint indexed auctionId,
        address indexed bidder,
        bytes32 commitment,
        uint deposit
    );
    
    //3.3 Logs relevant data when a bid is revealed
    event bidRevealed (
        uint indexed auctionId,
        address indexed bidder,
        uint bid
    );

    //3.4 Logs relevant data when the auction is finalised
    event auctionFinalised (
        uint indexed auctionId,
        address winner,
        uint winningBid,
        uint pricePaid
    );

    //3.5 Logs relevant data when the withdrawal is ready
    event WithdrawalReady (
        address user,
        uint amount
    );

    //3.6 Logs relevant data when the withdrawals are performed
    event WithdrawalPerformed (
        address indexed user,
        uint amount
    );

    //3.7 Logs relevant data when the seller is paid
    event SellerPaid (
        address indexed seller,
        uint amount
    );

    //4. MODIFIERS

    //4.1 Ensures auction is valid
    modifier auctionExists (uint auctionId) {
        require(auctionId < auctionCounter, "The auction does not exist.");
        _; 
    }

    //4.2 Ensures that the seller is the one sending the message
    modifier onlySeller (uint auctionId) {
        require(msg.sender == auctions[auctionId].seller, "This is not the seller.");
        _;
    }

    //5. CORE FUNCTIONS

    //5.1 Create a new auction, return the auction identifier
    function createAuction(address nftContract, uint tokenId, uint reservePrice, uint biddingDuration, uint revealDuration)
    external returns (uint) { 
        
        //5.1.1 ensure valid inputs
        require(nftContract != address(0), "This NFT contract is invalid."); 
        require(biddingDuration > 0, "The bidding duration must be > 0.");
        require(revealDuration > 0, "The reveal duration must be > 0.");

        //5.1.2 ensure seller owns the NFT
        IERC721 nft = IERC721(nftContract);
        require(nft.ownerOf(tokenId) == msg.sender, "This is not the NFT owner.");

        //5.1.3 initiate auction variables
        uint auctionId = auctionCounter++;
        uint biddingEnd = block.timestamp + biddingDuration;
        uint revealEnd = biddingEnd + revealDuration;

        //5.1.4 insert relevant inputs into Auction struct in auctions array, setting 0/false to unknowns
        auctions[auctionId] = auction({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            reservePrice: reservePrice,
            biddingEnd: biddingEnd,
            revealEnd: revealEnd,
            highestBidder: address(0), 
            highestBid: 0,
            secondHighestBid: 0,
            finalPrice: 0,
            finalised: false,
            paymentWithdrawn: false
        });

        //5.1.5 log Auction Created event into the transaction
        emit auctionCreated(
            auctionId, 
            msg.sender, 
            nftContract, 
            tokenId, 
            reservePrice, 
            biddingEnd, 
            revealEnd
        );

        return auctionId;
    }

    //5.2 Commit to the bid
    function commitBid(uint auctionId, bytes32 commitment)
    external payable auctionExists(auctionId) { 
        
        //5.2.1 get access to the specific auction in storage
        auction storage auction = auctions[auctionId]; 

        //5.2.2 ensure bid requirements are fulfilled
        require(block.timestamp < auction.biddingEnd, "Bidding ended, too late.");
        require(msg.value > 0, "Deposit not sent. Send a deposit >= than your bid.");
        require(commitment != bytes32(0), "Invalid committment");


        //5.2.3 get access to the bidder's bid for the auction
        bid storage bid = bids[auctionId][msg.sender];

        //5.2.4 ensure no one recommits (preventing front-running)
        require(bid.commitment == bytes32(0), "Bid already submitted. Only one bid allowed.");

        //5.2.5 initializing values to relevant variables
        bid.commitment = commitment;
        bid.deposit = msg.value;
        bid.revealed = false;
        bid.bidAmount = 0;
        bid.withdrawn = false;
        bidders[auctionId].push(msg.sender); 

        //5.2.6 logging event into transaction log
        emit bidCommitted(
            auctionId,
            msg.sender,
            commitment,
            msg.value
        );
    }

    //5.3 Reveal your bid
    function revealBid(uint auctionId, uint bidAmount, bytes32 nonce) 
    external auctionExists(auctionId) { 

        //5.3.1 access auction and bid from storage
        auction storage auction = auctions[auctionId];
        bid storage bid = bids[auctionId][msg.sender];

        //5.3.2 ensure variables/values needed are valid
        require(block.timestamp >= auction.biddingEnd, "Bidding in progress.");
        require(block.timestamp < auction.revealEnd, "Reveal period complete.");
        require(bid.commitment != bytes32(0), "No commitment found.");
        require(!bid.revealed, "Bids already revealed.");
        require(bidAmount <= bid.deposit, "Bid exceeds deposit given.");

        //5.3.3 verify the commitment
        bytes32 computedCommitment = keccak256(abi.encodePacked(bidAmount, nonce));
        require(computedCommitment == bid.commitment, "Invalid.");

        //5.3.4 complete bidding process
        bid.revealed = true;
        bid.bidAmount = bidAmount;

        //5.3.5 update the highest and second highest bids
        if(bidAmount >= auction.reservePrice) {
            if(bidAmount > auction.highestBid) { //new highest bid 
                auction.secondHighestBid = auction.highestBid;
                auction.highestBid = bidAmount;
                auction.highestBidder = msg.sender;
            } else if (bidAmount > auction.secondHighestBid) { //new second highest bid
                auction.secondHighestBid = bidAmount;
            }
        }

        //5.3.6 add event to transaction log
        emit bidRevealed(
            auctionId, 
            msg.sender, 
            bidAmount);
    }

    //5.4. Finalise auctions after bids are revealed
    function finaliseAuction(uint auctionId) external auctionExists(auctionId) {

        //5.4.1 access auction from storage
        auction storage auction = auctions[auctionId];

        //5.4.2 ensure all parameters are met for this function
        require(block.timestamp >= auction.revealEnd, "Reveal phase incomplete.");
        require(!auction.finalised, "Auction already finalised.");

        //5.4.3 officially finalise the auction
        auction.finalised = true;

        //5.4.4 determine the winner and the price to pay
        if(auction.highestBid >= auction.reservePrice) {
            uint price;
            if (auction.secondHighestBid >= auction.reservePrice){
                price = auction.secondHighestBid;
            } else {
                price = auction.reservePrice;
            }
            auction.finalPrice = price;

            //5.4.4.1 winner determined
            address winner = auction.highestBidder;
            
            //5.4.4.2 transfer the NFT
            IERC721(auction.nftContract).safeTransferFrom(
                auction.seller, 
                winner, 
                auction.tokenId);

            //5.4.4.3 add event to transaction log
            emit auctionFinalised(
                auctionId, 
                winner, 
                auction.highestBid,
                price);
        } else {
            //5.4.4.4 no valid bids in auction
            emit auctionFinalised(auctionId, address(0), 0, 0);
        }
    }

    //5.5 Withdraw (pull) funds for the bidder
    function withdraw(uint auctionId) external auctionExists(auctionId) {
        
        //5.5.1 ensure auction is finalised
        auction storage auction = auctions[auctionId];
        require(auction.finalised, "Auction not finalized");
        
        //5.5.2 ensure no malicious behaviour with bids
        bid storage bid = bids[auctionId][msg.sender];
        require(bid.deposit > 0, "No deposit");
        require(!bid.withdrawn, "Already withdrawn");
        
        uint refundAmount;
        
        //5.5.3 set amount to be refunded for all bidders
        if (msg.sender == auction.highestBidder && auction.highestBid >= auction.reservePrice) {
            if(bid.deposit > auction.finalPrice) {
                refundAmount = bid.deposit - auction.finalPrice;
            } else {
                refundAmount = 0;
            }       
        } else {
            refundAmount = bid.deposit;
        }
        
        //5.5.4 mark the bid as withdrawn
        bid.withdrawn = true; 
        
        //5.5.5 transfer the refund to the bidder
        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Transfer failed");
        
        //5.5.6 add event to transaction log
        emit WithdrawalPerformed(msg.sender, refundAmount);
    }

    // 5.6 Withdrawal function for the seller
    function withdrawSeller(uint256 auctionId) external auctionExists(auctionId) onlySeller(auctionId){
        auction storage auction = auctions[auctionId];
        require(auction.finalised, "Auction not finalized");    
        require(!auction.paymentWithdrawn, "Already withdrawn");
        require(auction.highestBid >= auction.reservePrice, "No sale");
        
        auction.paymentWithdrawn = true;   
        uint payment = auction.finalPrice;
        
        (bool success, ) = msg.sender.call{value: payment}("");
        require(success, "Transfer failed");
        
        emit SellerPaid(msg.sender, payment);
    }
    
    //6. GET FUNCTIONS

    //6.1 get auction details
    function getAuction(uint auctionId) external view auctionExists(auctionId) 
    returns(
        address seller,
        address nftContract,
        uint tokenId,
        uint reservePrice,
        uint biddingEnd,
        uint revealEnd,
        address highestBidder,
        uint highestBid,
        uint secondHighestBid,
        bool finalised
    ) {
        auction storage auction = auctions[auctionId];
        return(
            auction.seller,
            auction.nftContract,
            auction.tokenId,
            auction.reservePrice,
            auction.biddingEnd,
            auction.revealEnd,
            auction.highestBidder,
            auction.highestBid,
            auction.secondHighestBid,
            auction.finalised
        );
    }

    //6.2 get current auction ID
    function getCurrentAuctionID() external view returns(uint auctionID){
        return (auctionCounter - 1);
    }


    //7. HASH FUNCTION REQUIRED FOR THE COMMITMENT (BIDDER MUST DO THIS OFF-CHAIN, and use the hash to commit their bid)
    function generateCommitment(uint bidAmount, bytes32 nonce)
    external pure returns(bytes32){
            return keccak256(abi.encodePacked(bidAmount, nonce));
    }
}
