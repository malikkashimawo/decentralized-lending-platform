;; Decentralized Lending Protocol
;; Peer-to-peer lending platform with automated interest calculations and collateral management

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u2001))
(define-constant ERR_LOAN_NOT_FOUND (err u2002))
(define-constant ERR_INSUFFICIENT_FUNDS (err u2003))
(define-constant ERR_LOAN_NOT_ACTIVE (err u2004))
(define-constant ERR_INVALID_AMOUNT (err u2005))
(define-constant ERR_COLLATERAL_INSUFFICIENT (err u2006))
(define-constant ERR_ALREADY_FUNDED (err u2007))
(define-constant ERR_PAYMENT_OVERDUE (err u2008))
(define-constant ERR_LIQUIDATION_NOT_ALLOWED (err u2009))
(define-constant ERR_INVALID_INTEREST_RATE (err u2010))

;; Platform constants
(define-constant MIN_LOAN_AMOUNT u1000000) ;; 1 STX
(define-constant MAX_LOAN_AMOUNT u100000000000) ;; 100,000 STX
(define-constant MIN_COLLATERAL_RATIO u150) ;; 150%
(define-constant LIQUIDATION_THRESHOLD u125) ;; 125%
(define-constant LIQUIDATION_PENALTY u10) ;; 10%
(define-constant PLATFORM_FEE u5) ;; 0.5%
(define-constant MAX_INTEREST_RATE u5000) ;; 50% annually
(define-constant BLOCKS_PER_YEAR u52560) ;; ~365 days

;; Loan status constants
(define-constant LOAN_REQUESTED u1)
(define-constant LOAN_FUNDED u2)
(define-constant LOAN_ACTIVE u3)
(define-constant LOAN_REPAID u4)
(define-constant LOAN_DEFAULTED u5)
(define-constant LOAN_LIQUIDATED u6)

;; Data Variables
(define-data-var loan-counter uint u0)
(define-data-var total-loans-issued uint u0)
(define-data-var total-volume uint u0)
(define-data-var platform-fees-collected uint u0)
(define-data-var protocol-paused bool false)

;; Loan data structure
(define-map loans
  { loan-id: uint }
  {
    borrower: principal,
    lender: (optional principal),
    loan-amount: uint,
    collateral-amount: uint,
    interest-rate: uint,
    loan-duration: uint,
    loan-start: uint,
    last-payment: uint,
    amount-repaid: uint,
    status: uint,
    liquidation-price: uint
  }
)

;; Collateral tracking
(define-map collateral-deposits
  { borrower: principal, loan-id: uint }
  { amount: uint, locked: bool }
)

;; Interest calculations
(define-map interest-accrued
  { loan-id: uint }
  {
    principal-remaining: uint,
    interest-accumulated: uint,
    last-calculation: uint
  }
)

;; User loan tracking
(define-map user-loans
  { user: principal }
  { loan-ids: (list 100 uint) }
)

;; Lender portfolio tracking
(define-map lender-portfolios
  { lender: principal }
  {
    total-lent: uint,
    active-loans: uint,
    total-earned: uint
  }
)

;; Platform statistics
(define-map daily-stats
  { date: uint }
  {
    loans-created: uint,
    volume-funded: uint,
    defaults: uint
  }
)

;; Read-only functions

(define-read-only (get-loan (loan-id uint))
  (map-get? loans { loan-id: loan-id })
)

(define-read-only (get-loan-interest (loan-id uint))
  (map-get? interest-accrued { loan-id: loan-id })
)

(define-read-only (get-collateral-info (borrower principal) (loan-id uint))
  (map-get? collateral-deposits { borrower: borrower, loan-id: loan-id })
)

(define-read-only (get-user-loans (user principal))
  (default-to (list) (get loan-ids (map-get? user-loans { user: user })))
)

(define-read-only (get-lender-portfolio (lender principal))
  (default-to
    { total-lent: u0, active-loans: u0, total-earned: u0 }
    (map-get? lender-portfolios { lender: lender })
  )
)

(define-read-only (calculate-current-interest (loan-id uint))
  (let (
    (loan-data (unwrap! (get-loan loan-id) (err u0)))
    (interest-data (get-loan-interest loan-id))
  )
    (match interest-data
      data
      (let (
        (blocks-elapsed (- burn-block-height (get last-calculation data)))
        (annual-rate (get interest-rate loan-data))
        (principal (get principal-remaining data))
        (daily-rate (/ annual-rate BLOCKS_PER_YEAR))
      )
        (ok (/ (* principal (* daily-rate blocks-elapsed)) u10000))
      )
      (ok u0)
    )
  )
)

(define-read-only (calculate-collateral-ratio (loan-id uint))
  (match (get-loan loan-id)
    loan-data
    (let (
      (collateral (get collateral-amount loan-data))
      (loan-amount (get loan-amount loan-data))
    )
      (if (> loan-amount u0)
        (ok (/ (* collateral u100) loan-amount))
        (err u0)
      )
    )
    (err u0)
  )
)

(define-read-only (get-total-repayment-amount (loan-id uint))
  (let (
    (loan-data (unwrap! (get-loan loan-id) (err u0)))
    (current-interest (unwrap! (calculate-current-interest loan-id) (err u0)))
    (interest-data (get-loan-interest loan-id))
  )
    (match interest-data
      data
      (let (
        (total-interest (+ (get interest-accumulated data) current-interest))
        (remaining-principal (get principal-remaining data))
      )
        (ok (+ remaining-principal total-interest))
      )
      (ok (get loan-amount loan-data))
    )
  )
)

(define-read-only (get-platform-stats)
  {
    total-loans: (var-get loan-counter),
    total-volume: (var-get total-volume),
    fees-collected: (var-get platform-fees-collected),
    protocol-paused: (var-get protocol-paused)
  }
)

;; Public functions

(define-public (create-loan-request (loan-amount uint) (interest-rate uint) (duration uint) (collateral-amount uint))
  (let (
    (loan-id (+ (var-get loan-counter) u1))
  )
    (asserts! (not (var-get protocol-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (>= loan-amount MIN_LOAN_AMOUNT) ERR_INVALID_AMOUNT)
    (asserts! (<= loan-amount MAX_LOAN_AMOUNT) ERR_INVALID_AMOUNT)
    (asserts! (<= interest-rate MAX_INTEREST_RATE) ERR_INVALID_INTEREST_RATE)
    (asserts! (>= interest-rate u100) ERR_INVALID_INTEREST_RATE) ;; Min 1% annual
    (asserts! (>= duration u1440) ERR_INVALID_AMOUNT) ;; Min 10 days
    (asserts! (>= (/ (* collateral-amount u100) loan-amount) MIN_COLLATERAL_RATIO) ERR_COLLATERAL_INSUFFICIENT)
    
    ;; Lock collateral
    (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))
    
    ;; Create loan record
    (map-set loans
      { loan-id: loan-id }
      {
        borrower: tx-sender,
        lender: none,
        loan-amount: loan-amount,
        collateral-amount: collateral-amount,
        interest-rate: interest-rate,
        loan-duration: duration,
        loan-start: u0,
        last-payment: u0,
        amount-repaid: u0,
        status: LOAN_REQUESTED,
        liquidation-price: (/ (* loan-amount LIQUIDATION_THRESHOLD) u100)
      }
    )
    
    ;; Track collateral
    (map-set collateral-deposits
      { borrower: tx-sender, loan-id: loan-id }
      { amount: collateral-amount, locked: true }
    )
    
    ;; Update user loans
    (let (
      (current-loans (get-user-loans tx-sender))
    )
      (map-set user-loans
        { user: tx-sender }
        { loan-ids: (unwrap! (as-max-len? (append current-loans loan-id) u100) ERR_NOT_AUTHORIZED) }
      )
    )
    
    (var-set loan-counter loan-id)
    (ok loan-id)
  )
)

(define-public (fund-loan (loan-id uint))
  (let (
    (loan-data (unwrap! (get-loan loan-id) ERR_LOAN_NOT_FOUND))
  )
    (asserts! (not (var-get protocol-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (get status loan-data) LOAN_REQUESTED) ERR_ALREADY_FUNDED)
    (asserts! (not (is-eq tx-sender (get borrower loan-data))) ERR_NOT_AUTHORIZED)
    
    ;; Calculate platform fee
    (let (
      (platform-fee (/ (* (get loan-amount loan-data) PLATFORM_FEE) u1000))
      (amount-to-borrower (- (get loan-amount loan-data) platform-fee))
    )
      ;; Transfer loan amount minus fee to borrower
      (try! (stx-transfer? (get loan-amount loan-data) tx-sender (as-contract tx-sender)))
      (try! (as-contract (stx-transfer? amount-to-borrower tx-sender (get borrower loan-data))))
      
      ;; Update loan record
      (map-set loans
        { loan-id: loan-id }
        (merge loan-data {
          lender: (some tx-sender),
          status: LOAN_ACTIVE,
          loan-start: burn-block-height,
          last-payment: burn-block-height
        })
      )
      
      ;; Initialize interest tracking
      (map-set interest-accrued
        { loan-id: loan-id }
        {
          principal-remaining: (get loan-amount loan-data),
          interest-accumulated: u0,
          last-calculation: burn-block-height
        }
      )
      
      ;; Update lender portfolio
      (let (
        (portfolio (get-lender-portfolio tx-sender))
      )
        (map-set lender-portfolios
          { lender: tx-sender }
          {
            total-lent: (+ (get total-lent portfolio) (get loan-amount loan-data)),
            active-loans: (+ (get active-loans portfolio) u1),
            total-earned: (get total-earned portfolio)
          }
        )
      )
      
      ;; Update platform stats
      (var-set total-loans-issued (+ (var-get total-loans-issued) u1))
      (var-set total-volume (+ (var-get total-volume) (get loan-amount loan-data)))
      (var-set platform-fees-collected (+ (var-get platform-fees-collected) platform-fee))
      
      (ok loan-id)
    )
  )
)

(define-public (make-payment (loan-id uint) (payment-amount uint))
  (let (
    (loan-data (unwrap! (get-loan loan-id) ERR_LOAN_NOT_FOUND))
    (interest-data (unwrap! (get-loan-interest loan-id) ERR_LOAN_NOT_FOUND))
    (current-interest (unwrap! (calculate-current-interest loan-id) ERR_INVALID_AMOUNT))
  )
    (asserts! (not (var-get protocol-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq tx-sender (get borrower loan-data)) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (get status loan-data) LOAN_ACTIVE) ERR_LOAN_NOT_ACTIVE)
    (asserts! (> payment-amount u0) ERR_INVALID_AMOUNT)
    
    ;; Calculate updated interest
    (let (
      (total-interest (+ (get interest-accumulated interest-data) current-interest))
      (total-owed (+ (get principal-remaining interest-data) total-interest))
      (payment-to-lender payment-amount)
    )
      ;; Transfer payment
      (try! (stx-transfer? payment-amount tx-sender (unwrap! (get lender loan-data) ERR_NOT_AUTHORIZED)))
      
      ;; Update payment tracking
      (let (
        (new-amount-repaid (+ (get amount-repaid loan-data) payment-amount))
        (remaining-principal (if (<= total-owed payment-amount)
                              u0
                              (- (get principal-remaining interest-data) 
                                 (if (>= payment-amount total-interest)
                                     (- payment-amount total-interest)
                                     u0))))
        (new-status (if (<= total-owed payment-amount) LOAN_REPAID LOAN_ACTIVE))
      )
        ;; Update loan record
        (map-set loans
          { loan-id: loan-id }
          (merge loan-data {
            amount-repaid: new-amount-repaid,
            last-payment: burn-block-height,
            status: new-status
          })
        )
        
        ;; Update interest tracking
        (map-set interest-accrued
          { loan-id: loan-id }
          {
            principal-remaining: remaining-principal,
            interest-accumulated: (if (>= payment-amount total-interest) u0 (- total-interest payment-amount)),
            last-calculation: burn-block-height
          }
        )
        
        ;; If loan is fully repaid, release collateral
        (begin
          (if (is-eq new-status LOAN_REPAID)
            (begin
              (try! (as-contract (stx-transfer? (get collateral-amount loan-data) tx-sender (get borrower loan-data))))
              (map-set collateral-deposits
                { borrower: (get borrower loan-data), loan-id: loan-id }
                { amount: u0, locked: false }
              )
              
              ;; Update lender portfolio
              (let (
                (portfolio (get-lender-portfolio (unwrap! (get lender loan-data) ERR_NOT_AUTHORIZED)))
              )
                (map-set lender-portfolios
                  { lender: (unwrap! (get lender loan-data) ERR_NOT_AUTHORIZED) }
                  (merge portfolio {
                    active-loans: (- (get active-loans portfolio) u1),
                    total-earned: (+ (get total-earned portfolio) total-interest)
                  })
                )
              )
            )
            true
          )
          
          (ok payment-amount)
        )
      )
    )
  )
)

(define-public (liquidate-loan (loan-id uint))
  (let (
    (loan-data (unwrap! (get-loan loan-id) ERR_LOAN_NOT_FOUND))
    (collateral-ratio (unwrap! (calculate-collateral-ratio loan-id) ERR_INVALID_AMOUNT))
  )
    (asserts! (not (var-get protocol-paused)) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (get status loan-data) LOAN_ACTIVE) ERR_LOAN_NOT_ACTIVE)
    (asserts! (<= collateral-ratio LIQUIDATION_THRESHOLD) ERR_LIQUIDATION_NOT_ALLOWED)
    
    ;; Calculate liquidation amounts
    (let (
      (total-debt (unwrap! (get-total-repayment-amount loan-id) ERR_INVALID_AMOUNT))
      (penalty (/ (* (get collateral-amount loan-data) LIQUIDATION_PENALTY) u100))
      (liquidator-reward penalty)
      (lender-recovery (if (<= total-debt (- (get collateral-amount loan-data) penalty)) 
                         total-debt 
                         (- (get collateral-amount loan-data) penalty)))
      (remaining-collateral (- (get collateral-amount loan-data) penalty lender-recovery))
    )
      ;; Transfer liquidation proceeds
      (try! (as-contract (stx-transfer? lender-recovery tx-sender (unwrap! (get lender loan-data) ERR_NOT_AUTHORIZED))))
      (try! (as-contract (stx-transfer? liquidator-reward tx-sender tx-sender)))
      
      ;; Return remaining collateral to borrower if any
      (begin
        (if (> remaining-collateral u0)
          (try! (as-contract (stx-transfer? remaining-collateral tx-sender (get borrower loan-data))))
          true
        )
      )
      
      ;; Update loan status
      (map-set loans
        { loan-id: loan-id }
        (merge loan-data { status: LOAN_LIQUIDATED })
      )
      
      ;; Update collateral tracking
      (map-set collateral-deposits
        { borrower: (get borrower loan-data), loan-id: loan-id }
        { amount: u0, locked: false }
      )
      
      (ok loan-id)
    )
  )
)

(define-public (emergency-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set protocol-paused true)
    (ok true)
  )
)

(define-public (resume-protocol)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set protocol-paused false)
    (ok true)
  )
)

(define-public (withdraw-platform-fees (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (<= amount (var-get platform-fees-collected)) ERR_INSUFFICIENT_FUNDS)
    (try! (as-contract (stx-transfer? amount tx-sender CONTRACT_OWNER)))
    (var-set platform-fees-collected (- (var-get platform-fees-collected) amount))
    (ok amount)
  )
)

;; title: lending-protocol
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

