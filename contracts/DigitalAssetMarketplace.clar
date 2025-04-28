;; Digital Asset Marketplace
;; Enables creators to tokenize and sell digital assets with royalty mechanisms

(define-map asset-transactions
    { transaction-id: (buff 32), asset: principal, amount: uint, buyer: principal }
    { completed: bool, timestamp: uint })

(define-map registered-assets principal bool)
(define-map processed-transactions (buff 32) bool)
(define-map pending-payments {asset: principal, account: principal} uint)
(define-trait asset-trait
    (
        (transfer (uint principal principal (optional (buff 34))) (response bool uint))
        (get-name () (response (string-ascii 32) uint))
        (get-symbol () (response (string-ascii 32) uint))
        (get-decimals () (response uint uint))
        (get-balance (principal) (response uint uint))
        (get-total-supply () (response uint uint))
        (get-token-uri () (response (optional (string-utf8 256)) uint))
    )
)

(define-constant MINIMUM_PURCHASE u100000)
(define-constant PAYMENT_EXPIRY u144)
(define-constant CREATOR_COMMISSION u100) ;; 1% commission

;; Error codes
(define-constant ERR_NOT_AUTHORIZED (err u1))
(define-constant ERR_BELOW_MINIMUM (err u2))
(define-constant ERR_INSUFFICIENT_FUNDS (err u3))
(define-constant ERR_MARKETPLACE_PAUSED (err u4))
(define-constant ERR_INVALID_ACTION (err u5))
(define-constant ERR_INVALID_OPERATION (err u6))
(define-constant ERR_ALREADY_PURCHASED (err u7))
(define-constant ERR_TRANSACTION_TIMEOUT (err u8))
(define-constant ERR_INVALID_BUYER (err u9))
(define-constant ERR_INVALID_TRANSACTION_ID (err u10))
(define-constant ERR_ASSET_NOT_REGISTERED (err u11))
(define-constant ERR_PAYMENT_ERROR (err u12))


;; Data Variables and Maps
(define-data-var marketplace-owner principal tx-sender)
(define-data-var marketplace-paused bool false)
(define-data-var minimum-purchase-amount uint MINIMUM_PURCHASE)
(define-data-var commission-rate uint CREATOR_COMMISSION)

(define-map creator-balances {asset: principal, account: principal} uint)

;; Helper Functions
(define-private (meets-minimum-amount (amount uint))
    (>= amount (var-get minimum-purchase-amount)))

(define-private (is-marketplace-owner)
    (is-eq tx-sender (var-get marketplace-owner)))

(define-private (check-transaction-status (transaction-id (buff 32)))
    (default-to false (map-get? processed-transactions transaction-id)))

(define-private (validate-buyer (buyer principal))
    (and
        (not (is-eq buyer tx-sender))
        (not (is-eq buyer (var-get marketplace-owner)))))

(define-private (is-asset-registered (asset principal))
  (default-to false (map-get? registered-assets asset)))

(define-private (get-balance-amount (balance-data {asset: principal, account: principal}))
  (default-to u0 (map-get? creator-balances balance-data)))

(define-private (calculate-creator-commission (amount uint))
  (let ((commission (/ (* amount (var-get commission-rate)) u10000)))
    (if (> commission u0)
        (ok commission)
        (err u12))))

(define-private (validate-purchase-data (asset <asset-trait>) (amount uint))
    (let ((sender tx-sender))
        (asserts! (not (var-get marketplace-paused)) ERR_MARKETPLACE_PAUSED)
        (asserts! (meets-minimum-amount amount) ERR_BELOW_MINIMUM)
        (asserts! (is-asset-registered (contract-of asset)) ERR_ASSET_NOT_REGISTERED)
        (asserts! (>= (get-balance-amount {asset: (contract-of asset), account: sender}) amount) ERR_INSUFFICIENT_FUNDS)
        (ok true)))

;; Public Functions
(define-public (request-purchase (transaction-id (buff 32)) (asset <asset-trait>) (amount uint) (buyer principal))
    (begin
        (asserts! (meets-minimum-amount amount) ERR_BELOW_MINIMUM)
        (asserts! (> (len transaction-id) u0) ERR_INVALID_TRANSACTION_ID)
        (asserts! (validate-buyer buyer) ERR_INVALID_BUYER)
        (asserts! (is-asset-registered (contract-of asset)) ERR_ASSET_NOT_REGISTERED)
        (let ((validated (try! (validate-purchase-data asset amount))))
            (try! (contract-call? asset transfer amount tx-sender (as-contract tx-sender) none))
            (map-set processed-transactions transaction-id true)
            (map-set asset-transactions
                { transaction-id: transaction-id, asset: (contract-of asset), amount: amount, buyer: buyer }
                { completed: false, timestamp: burn-block-height })
            (ok true))))

(define-public (complete-purchase (transaction-id (buff 32)) (asset <asset-trait>) (amount uint) (buyer principal))
    (begin
        (asserts! (is-marketplace-owner) ERR_NOT_AUTHORIZED)
        (asserts! (meets-minimum-amount amount) ERR_BELOW_MINIMUM)
        (asserts! (> (len transaction-id) u0) ERR_INVALID_TRANSACTION_ID)
        (asserts! (validate-buyer buyer) ERR_INVALID_BUYER)
        (asserts! (is-asset-registered (contract-of asset)) ERR_ASSET_NOT_REGISTERED)
        (match (map-get? asset-transactions { transaction-id: transaction-id, asset: (contract-of asset), amount: amount, buyer: buyer })
            record-data (begin
                (asserts! (not (get completed record-data)) ERR_INVALID_ACTION)
                (let ((commission (try! (calculate-creator-commission amount)))
                      (purchase-amount (- amount commission)))
                    (try! (as-contract (contract-call? asset transfer
                            commission
                            (as-contract tx-sender)
                            (var-get marketplace-owner)
                            none)))
                    (try! (as-contract (contract-call? asset transfer
                        purchase-amount
                        (as-contract tx-sender)
                        buyer
                        none)))
                    (ok (map-set asset-transactions
                        { transaction-id: transaction-id, asset: (contract-of asset), amount: amount, buyer: buyer }
                        { completed: true, timestamp: burn-block-height }))))
            ERR_INVALID_ACTION)))

;; Admin function to register asset
(define-public (register-asset (asset <asset-trait>))
  (begin
    (asserts! (is-marketplace-owner) ERR_NOT_AUTHORIZED)
    (asserts! (is-ok (contract-call? asset get-name)) ERR_INVALID_ACTION)
    (ok (map-set registered-assets (contract-of asset) true))))

;; Admin function to unregister asset
(define-public (unregister-asset (asset principal))
  (begin
    (asserts! (is-marketplace-owner) ERR_NOT_AUTHORIZED)
    (asserts! (is-asset-registered asset) ERR_ASSET_NOT_REGISTERED)
    (ok (map-delete registered-assets asset))))

;; Initialize contract (add initial registered asset - e.g., STX)
(begin
    (map-set registered-assets .stx true) ;; Example: STX is initially registered
    (ok true))