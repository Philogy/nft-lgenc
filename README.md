# Lgenc NFT Lending Pool

PoC simple yet powerful NFT for ETH lending pool design. Allows for advanced operations such as
refinancing, flash loans and creating / repaying multiple loans in one tx.

## ⚠️ WARNING: NOT SECURE
This implementation is missing many basic checks and features and merely serves to prove the general
design. Features / security checks that are missing:

- Slippage checks in borrow
- Late repayment penalties
- Interest rate based on utilization
- Price oracle
- Quality of life improvements (max withdraw when amount `0xff...fff`, max out borrow amount, etc.)
