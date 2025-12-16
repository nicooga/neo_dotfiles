//
//  CardActivationViewController.swift
//  Zero
//
//  Created by Josh Wright on 3/13/18.
//  Copyright © 2018 zero. All rights reserved.
//

import UIKit
import ZeroUI
import BonMot
import Core


typealias CVC = String
typealias ExpiryDate = String // 1220 if the expiry date is Dec 2020

enum CardActivationState {
    case inputExpiryDate
    case inputCVC
    case inputPIN
    case verifyPIN
    case pinsDidntMatch
}


class CardActivationViewController: ModalViewController {
    
    private let verifyTitleLabel: UILabel = {
        let label = UILabel()
        label.text = "Verify your card info"
        label.font = .headingLarge
        label.textColor = .textAndIcon900
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "cardActivation.title"
        
        return label
    }()
    
    private let expirationDateField: TextFormInputView = {
        let textView = TextFormInputView()
        textView.type = .expirationDate
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityIdentifier = "cardActivation.expirationDate"
        
        return textView
    }()
    
    private let cvcField: TextFormInputView = {
        let textView = TextFormInputView()
        textView.type = .CVC
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityIdentifier = "cardActivation.cvcField"
        
        return textView
    }()
    
    private let helpButton: UIButton = {
        let btn = UIButton()
        btn.backgroundColor = .clear
        btn.translatesAutoresizingMaskIntoConstraints = false
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.bodyMedium,
            .foregroundColor: UIColor.levelDarkBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let attributeString = NSMutableAttributedString(
            string: "Where can I find this?".localize(),
            attributes: attributes
        )
        btn.setAttributedTitle(attributeString, for: .normal)
        btn.accessibilityIdentifier = "cardActivation.helpButton"
        
        return btn
    }()
    
    private let continueButton: UnifiedLoadingButton = {
        let btn = UnifiedLoadingButton()
        btn.buttonState = .primary
        btn.setTitleWithLargeFont("Continue".uppercased().localize())
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.accessibilityIdentifier = "cardActivation.continueButton"
        return btn
    }()

    var activationSucceededCallback: Callback?
    
    var cvc: CVC? {
        return cvcField.getFieldText()
    }
    var expiry: ExpiryDate? {
        return expirationDateField.getFieldText()
    }
    
    private var state: CardActivationState = .inputExpiryDate
    
    private var cardPendingActivation: Card? {
        guard CardTrackerViewController.isPhysicalCardOnItsWay(self) else { return nil }
        guard let cardToBeActivatedUUID = Customer.current?.trackerCardUUID else {
            logError("tried grabbing a card to activate and set a pin, but we didnt get the card uuid to activate from the card tracker")
            return nil
        }
        cardTrackerID = Customer.current?.trackerCardUUID
        return Card.fetch().first(where: { return $0.uuid == cardToBeActivatedUUID })
    }
    
    // track this as once the card is activated, it no longer lives in the tracker
    // and we need the ID to set card PIN
    private var cardTrackerID: String?
    
    // once the card has been activated, it's UUID is no longer stored in the
    // card tracker, so above var is nil
    private var activatedCard: Card? {
        if let cardToBeActivatedUUID = (Customer.current?.trackerCardUUID ?? cardTrackerID) {
            return Card.fetch().first(where: { return $0.uuid == cardToBeActivatedUUID })
        }
        return Card.current
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .background100
        title = "Activate Debit card".uppercased().localize()
        
        setupSubviews()
        setupConstraints()
        setupActions()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        expirationDateField.selectField()
    }
    
    private func setupSubviews() {
        view.addSubview(verifyTitleLabel)
        view.addSubview(expirationDateField)
        view.addSubview(cvcField)
        view.addSubview(helpButton)
        view.addSubview(continueButton)
        
        navigationItem.rightBarButtonItem = .empty
        
        expirationDateField.delegate = self
        cvcField.delegate = self
    }
    
    private func setupConstraints() {
        NSLayoutConstraint.activate([
            verifyTitleLabel.topAnchor.constraint(equalTo: view.safeTopAnchor, constant: 40),
            verifyTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            verifyTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            expirationDateField.topAnchor.constraint(equalTo: verifyTitleLabel.bottomAnchor, constant: 40),
            expirationDateField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            expirationDateField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            cvcField.topAnchor.constraint(equalTo: expirationDateField.bottomAnchor, constant: 25),
            cvcField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cvcField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            helpButton.topAnchor.constraint(equalTo: cvcField.bottomAnchor, constant: 25),
            helpButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            continueButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40),
            continueButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            continueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            continueButton.heightAnchor.constraint(equalToConstant: 56)
        ])
    }
    
    private func setupActions() {
        continueButton.addTarget(self, action: #selector(continueButtonTapped), for: .touchUpInside)
        helpButton.addTarget(self, action: #selector(whereCanIFindTapped), for: .touchUpInside)
    }
    
    @objc private func whereCanIFindTapped() {
        let customView = UIImageView()
        customView.translatesAutoresizingMaskIntoConstraints = false
        customView.contentMode = .scaleAspectFill
        customView.layer.cornerRadius = 16
        customView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMinXMinYCorner]
        customView.layer.masksToBounds = true
        customView.widthAnchor.constraint(equalToConstant: view.frame.width).isActive = true
        customView.image = UIImage(named: "card_back_with_gray")
        let customViewComponent = AlertV2Component.custom(customViewInserted: customView, location: .top)
        let title = AlertV2Component.title("Where can I find this?".localize())
        let alertContent =  "You can find the expiration date and CVC on the back of your Debit Card.".localize().styled(with: .standardUnifiedApp)
        let content = AlertV2Component.attributedContent(alertContent)
        let components = [customViewComponent, title, content]
        
        let alert = AlertViewControllerV2.generate(components: components)
        alert.hideHandleAndMoveContentUp = true
        let action = AlertActionV2(alertButtonStyle: .defaultState, title: "Got it".uppercased().localize(), action: nil)
        alert.setupSingleAction(action)
        present(alert, animated: true)
    }
    
    @objc private func continueButtonTapped() {
        continueButton.isActivityOccurring = true
        
        guard let expiry = expiry, !expiry.isEmpty else {
            expirationDateField.hasError(true)
            continueButton.isActivityOccurring = false
            // TODO: Set error alert if needed
            return
        }
        
        guard let cvc = cvc, !cvc.isEmpty else {
            cvcField.hasError(true)
            continueButton.isActivityOccurring = false
            return
        }
        
        let month = String(expiry.prefix(2))
        let year = String(expiry.suffix(2))
        let activationInfo = AccountActivationInfo(expMonth: month, expYear: year, cvv: cvc)
        
        cardPendingActivation?.activate(with: activationInfo)
            .send { [weak self] response in
                self?.continueButton.isActivityOccurring = false
                switch response {
                case .error(let error):
                    self?.cvcField.hasError(true)
                    self?.expirationDateField.hasError(true)
                    if error.asNetworkError?.zeroClientMessage != nil || (error.asNetworkError?.zeroHasMobileErrorParams ?? false) {
                        return handleErrorAsToastOrBanner("This combination is incorrect.", error: error, dismissAction: nil, completeDismissalActionWithBanner: true)
                    }
                case .success:
                    let pinVC = PinV2ViewController()
                    pinVC.state = .cardActivation
                    self?.navigationController?.pushViewController(pinVC, animated: true)
                }
            }
    }
}

extension CardActivationViewController: TextFormInputDelegate {
    func finishedInsertingExpirationDate() {
        expirationDateField.deselect()
        cvcField.selectField()
    }
    
    func finishedInsertingCVC() {
        cvcField.deselect()
    }
}

extension Storyboard {
    
    enum CardActivation: String, StoryboardView {
        
        case activateCard
        
        private static let storyboard = UIStoryboard(name: "CardActivation", bundle: nil)
        
        var identifier: String { return rawValue }
        
        var viewController: UIViewController {
            return CardActivation.storyboard.instantiateViewController(withIdentifier: rawValue)
        }
    }
}
