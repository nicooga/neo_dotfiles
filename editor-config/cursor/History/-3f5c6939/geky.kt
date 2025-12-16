package inc.zerofinancial.level.app.ui.product

import androidx.annotation.VisibleForTesting
import com.squareup.moshi.Moshi
import dagger.hilt.android.lifecycle.HiltViewModel
import inc.zerofinancial.level.NavGraphLoggedInDirections.Companion.actionGlobalToPaymentHistoryFragment
import inc.zerofinancial.level.NavGraphLoggedInDirections.Companion.actionGlobalToStatementListFragment
import inc.zerofinancial.level.R
import inc.zerofinancial.level.app.deeplink.DeepLinkIdentifier
import inc.zerofinancial.level.app.deeplink.IAppScreenDeeplink
import inc.zerofinancial.level.app.deeplink.IWorkflowDeeplink
import inc.zerofinancial.level.app.ui.base.BaseViewHolderModel
import inc.zerofinancial.level.app.ui.base.BaseViewModelImpl
import inc.zerofinancial.level.app.ui.base.BottomDialogData
import inc.zerofinancial.level.app.ui.holders.generics.FeatureMenuSimpleHolder
import inc.zerofinancial.level.app.ui.holders.generics.FeatureSimpleBannerHolder
import inc.zerofinancial.level.app.ui.holders.generics.FeatureSimpleButtonHolder
import inc.zerofinancial.level.app.ui.holders.generics.FeatureSimpleCTAHolder
import inc.zerofinancial.level.app.ui.holders.generics.FeatureSimpleClickHolder
import inc.zerofinancial.level.app.ui.holders.product.CreditCardCashBackRewardsHolder
import inc.zerofinancial.level.app.ui.holders.product.CreditCardDetailsAmountHolder
import inc.zerofinancial.level.app.ui.holders.product.CreditCardDetailsCardHolder
import inc.zerofinancial.level.app.ui.holders.product.CreditCardDetailsLoadingHolder
import inc.zerofinancial.level.app.ui.holders.product.CreditCardLoadingHolder
import inc.zerofinancial.level.app.ui.holders.product.CreditCardPaymentDetailsHolder
import inc.zerofinancial.level.app.ui.holders.product.CreditCardPaymentOverviewHolder
import inc.zerofinancial.level.app.ui.holders.product.CreditCardPaymentProtectionHolder
import inc.zerofinancial.level.app.ui.holders.product.CreditCardTrxOverviewHolder
import inc.zerofinancial.level.app.ui.holders.product.QuickActionMenuHolder
import inc.zerofinancial.level.app.ui.holders.product.QuickActionMenuHolder.MenuData
import inc.zerofinancial.level.app.ui.product.CreditCardDetailsFragmentDirections.Companion.actionGlobalToCreditCardTrxListDeprecatedFragment
import inc.zerofinancial.level.app.ui.product.CreditCardDetailsFragmentDirections.Companion.actionGlobalToCreditCardTrxListFragment
import inc.zerofinancial.level.app.ui.product.CreditCardDetailsFragmentDirections.Companion.actionGlobalToMoreActionsMenuFragment
import inc.zerofinancial.level.app.ui.product.ProductType.CREDIT_CARD
import inc.zerofinancial.level.app.ui.workflow.StartWorkflowData
import inc.zerofinancial.level.app.ui.workflow.WorkflowProductType
import inc.zerofinancial.level.app.ui.workflow.WorkflowProductType.CREDIT
import inc.zerofinancial.level.app.ui.workflow.WorkflowProductType.LOAN
import inc.zerofinancial.level.app.ui.workflow.WorkflowUtils
import inc.zerofinancial.level.app.ui.workflow.WorkflowUtils.Workflow
import inc.zerofinancial.level.app.ui.workflow.WorkflowUtils.Workflow.ACTIVATE_CARD
import inc.zerofinancial.level.app.ui.workflow.WorkflowUtils.Workflow.MAKE_CARD_PAYMENT
import inc.zerofinancial.level.app.ui.workflow.WorkflowUtils.Workflow.MANAGE_CARD_LOCK
import inc.zerofinancial.level.app.ui.workflow.WorkflowUtils.startWorkflow
import inc.zerofinancial.level.app.utils.ICoroutineContextProvider
import inc.zerofinancial.level.app.utils.MutableSingleLiveData
import inc.zerofinancial.level.app.utils.NavigationManager.xHandleCreditPaymentClickAction
import inc.zerofinancial.level.app.utils.SingleLiveData
import inc.zerofinancial.level.app.utils.parseList
import inc.zerofinancial.level.core.base.DialogDataEntity
import inc.zerofinancial.level.core.coroutine.xZip
import inc.zerofinancial.level.core.extensions.xDollarCentsCurrencyString
import inc.zerofinancial.level.core.extensions.xMonthDayYearCalendar
import inc.zerofinancial.level.core.extensions.xToCents
import inc.zerofinancial.level.core.extensions.xToDate
import inc.zerofinancial.level.core.general.OptionEntity
import inc.zerofinancial.level.core.recycler.DynamicRecyclerAdapter
import inc.zerofinancial.level.core.test.AccessibilityIds.CreditCardProductScreen.credit_card_activate_card_button
import inc.zerofinancial.level.core.test.AccessibilityIds.CreditCardProductScreen.credit_card_lock_card_button
import inc.zerofinancial.level.core.test.AccessibilityIds.CreditCardProductScreen.credit_card_make_payment_button
import inc.zerofinancial.level.core.test.AccessibilityIds.CreditCardProductScreen.credit_card_more_actions_button
import inc.zerofinancial.level.core.test.AccessibilityIds.CreditCardProductScreen.credit_card_payment_button
import inc.zerofinancial.level.core.test.AccessibilityIds.CreditCardProductScreen.credit_card_statements_button
import inc.zerofinancial.level.domain.bridgemodels.CreditCardProductAndPaymentsModel
import inc.zerofinancial.level.domain.bridgemodels.CustomerGraphQLModel
import inc.zerofinancial.level.domain.usecasemodels.CreditCardPaymentStatus
import inc.zerofinancial.level.domain.usecasemodels.CreditCardTrxOverview
import inc.zerofinancial.level.domain.usecasemodels.Result
import inc.zerofinancial.level.domain.usecasemodels.Result.ErrorType.Unknown
import inc.zerofinancial.level.domain.usecasemodels.toPaymentDetailData
import inc.zerofinancial.level.domain.usecasemodels.toPaymentOverviewData
import inc.zerofinancial.level.domain.usecases.ICustomerGraphQLUseCases
import inc.zerofinancial.level.domain.usecases.IProductUseCases
import inc.zerofinancial.level.domain.usecases.ITrxUseCases
import inc.zerofinancial.level.manager.ZeroPrefsManager
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import javax.inject.Inject

interface ICreditCardDetailsViewModel {

    val showProgressAndDisableTouch: SingleLiveData<Boolean>
    val startWorkflow: SingleLiveData<Triple<Int, StartWorkflowData, WorkflowProductType>>
    val deeplinkNavigation: SingleLiveData<Triple<String, DeepLinkIdentifier, String?>>

    fun loadCreditDetails(requestId: Long)
    fun pushTopImmutableList(models: List<BaseViewHolderModel>)
    fun pushBottomImmutableList(models: List<BaseViewHolderModel>)

    fun setupTopModelDataUpdateListener(listener: DynamicRecyclerAdapter.DataUpdateListener)
    fun setupBottomModelDataUpdateListener(listener: DynamicRecyclerAdapter.DataUpdateListener)
    fun enqueueRequest(productUuid: String?, force: Boolean)
    fun checkNextQueuedRequest(productUuid: String?)

    fun restoreValues(productUuid: String?)
    fun clearValues()
}

@HiltViewModel
open class CreditCardDetailsViewModelImpl @Inject constructor(
    override val contextProvider: ICoroutineContextProvider,
    private val productUseCases: IProductUseCases,
    private val trxUseCases: ITrxUseCases,
    private val customerUseCases: ICustomerGraphQLUseCases,
    private val prefsManager: ZeroPrefsManager,
    private val moshi: Moshi
): ICreditCardDetailsViewModel, IWorkflowDeeplink, IAppScreenDeeplink, BaseViewModelImpl(contextProvider) {

    @Inject lateinit var topAdapter: DynamicRecyclerAdapter
    @Inject lateinit var bottomSheetAdapter: DynamicRecyclerAdapter

    @VisibleForTesting(otherwise = VisibleForTesting.PROTECTED)
    val deeplinkNavigationPrivate = MutableSingleLiveData<Triple<String, DeepLinkIdentifier, String?>>()
    override val deeplinkNavigation: SingleLiveData<Triple<String, DeepLinkIdentifier, String?>> = deeplinkNavigationPrivate

    @VisibleForTesting(otherwise = VisibleForTesting.PROTECTED)
    val startWorkflowPrivate = MutableSingleLiveData<Triple<Int, StartWorkflowData, WorkflowProductType>>()
    override val startWorkflow: SingleLiveData<Triple<Int, StartWorkflowData, WorkflowProductType>> = startWorkflowPrivate

    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    val titlePrivate = MutableSingleLiveData<String>()
    val title: SingleLiveData<String> = titlePrivate

    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    val topModelsPrivate = MutableSingleLiveData<List<BaseViewHolderModel>?>()
    val topModels: SingleLiveData<List<BaseViewHolderModel>?> = topModelsPrivate

    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    val bottomModelsPrivate = MutableSingleLiveData<List<BaseViewHolderModel>?>()
    val bottomModels: SingleLiveData<List<BaseViewHolderModel>?> = bottomModelsPrivate

    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    val showDateOptionsPrivate = MutableSingleLiveData<List<OptionEntity>>()
    val showDateOptions: SingleLiveData<List<OptionEntity>> = showDateOptionsPrivate

    @VisibleForTesting(otherwise = VisibleForTesting.PROTECTED)
    val showProgressAndDisableTouchPrivate = MutableSingleLiveData<Boolean>()
    override val showProgressAndDisableTouch: SingleLiveData<Boolean> = showProgressAndDisableTouchPrivate

    private var isTrxSyncInProgress = false
    private var mProductUuid = AtomicReference<String>(null)
    private var isLoaded = AtomicBoolean(false)
    private var isLoadingInProgress = AtomicBoolean(false)
    private var cancelRequests = AtomicBoolean(false)
    private var rawDates: List<String> = listOf()
    private var dateOptions = mutableListOf<OptionEntity>()

    private var mPendingDeeplinkWorkflow = AtomicReference<Triple<Workflow, WorkflowProductType, Int>>(null)
    private var mPendingDeeplinkScreen = AtomicReference<DeepLinkIdentifier>(null)

    private var currentRequestId = AtomicLong(-1)
    private var requestIdsInProgress = Collections.synchronizedSortedSet(sortedSetOf<Long>())

    override suspend fun setup() = Unit

    override fun restoreValues(productUuid: String?) {
        cancelRequests.set(false)
        topModelsPrivate.setValue(null)
        bottomModelsPrivate.setValue(null)
        checkNextQueuedRequest(productUuid)
    }

    override fun clearValues() {
        cancelRequests.set(true)
        topModelsPrivate.setValue(null)
        bottomModelsPrivate.setValue(null)
    }

    override fun setupTopModelDataUpdateListener(listener: DynamicRecyclerAdapter.DataUpdateListener) {
        this.topAdapter.setDataUpdateListener(listener)
    }

    override fun setupBottomModelDataUpdateListener(listener: DynamicRecyclerAdapter.DataUpdateListener) {
        this.bottomSheetAdapter.setDataUpdateListener(listener)
    }

    override fun enqueueRequest(productUuid: String?, force: Boolean) {
        if (requestIdsInProgress.size < 2) {
            requestIdsInProgress.add(System.currentTimeMillis())
        }
        checkNextQueuedRequest(productUuid)
    }

    override fun checkNextQueuedRequest(productUuid: String?) {
        if (currentRequestId.get() > 0) {
            return
        }
        if (mProductUuid.get().isNullOrBlank() && !productUuid.isNullOrBlank()) {
            mProductUuid.set(productUuid)
        }
        if (!requestIdsInProgress.isEmpty() && currentRequestId.get() < 0) {
            loadCreditDetails(requestIdsInProgress.first())
        }
    }

    override fun loadCreditDetails(requestId: Long) {
        if (mProductUuid.get().isNullOrBlank()) {
            currentRequestId.set(-1)
            requestIdsInProgress.clear()
            dismissPrivate.postValue(Unknown())
            return
        }
        if (isLoadingInProgress.get()) {
            return
        }
        val productUuid = mProductUuid.get()
        currentRequestId.set(requestId)
        requestIdsInProgress.remove(requestId)
        prefsManager.cacheLastViewedProduct(CREDIT.raw, productUuid)
        launchCoroutineIO {
            isLoadingInProgress.set(true)
            if (!isLoaded.get()) {
                populateLoadingModelIfNeeded(null, null, null, true)
//                Log.d("CreditCardDetailsViewModelImpl", "populate model loading")
                productUseCases.getLocalCreditProduct(productUuid)
                    .xZip(
                        trxUseCases.getLocalCreditCardTrxGraphQL(productUuid, null, null),
                        customerUseCases.getCurrentCustomerGraphQL()
                    ) { productRes, trxRes, customerRes -> Triple(productRes.data, trxRes.data, customerRes.data) }
                    .collect {
                        populateLoadingModelIfNeeded(it.first, it.second?.map { it.toTrxOverviewData() }, it.third, true)
//                        Log.d("CreditCardDetailsViewModelImpl", "populate model if needed")
                    }

                productUseCases.getLocalCreditCardStatementDates(productUuid).collect { productRes ->
                    if (productRes.data == null) {
                        dismissPrivate.postValue(Unknown())
                        return@collect
                    }
                    rawDates = moshi.parseList(productRes.data.statementDates ?: "[]") ?: listOf()
                    dateOptions.clear()
                    val defaultOption = OptionEntity("", "Recent")
                    dateOptions.add(defaultOption)
                    dateOptions.addAll(rawDates.map { OptionEntity(it, it.xMonthDayYearCalendar()) })
                }
            }
//            if (prefsManager.currentEnvPref != PROD.raw) {
//                productUseCases.syncRemoteCreditProductDetails(productUuid)
//                    .zip(trxUseCases.syncFirstBatchCreditCardTrx(productUuid)) { _, _ -> }
//                    .collect {
//                        launchCoroutineIO {
//                            syncAllCreditCardTrx(productUuid)
//                            loadProductDetails(productUuid, false)
//                        }
//                    }
//            } else {
                productUseCases.syncRemoteCreditProductDetails(productUuid).collect {
                        launchCoroutineIO {
                            if (it !is Result.Loading) {
                                loadProductDetails(productUuid, false)
                            }
                        }
                    }
//            }
        }
    }

    override fun pushTopImmutableList(models: List<BaseViewHolderModel>) { topAdapter.pushImmutableList(models) }

    override fun pushBottomImmutableList(models: List<BaseViewHolderModel>) { bottomSheetAdapter.pushImmutableList(models) }

    override fun startWorkflow(workflowData: Triple<Workflow, WorkflowProductType, Int>?) {
        showProgressAndDisableTouchPrivate.postValue(true)
        mPendingDeeplinkWorkflow.set(workflowData)
        mPendingDeeplinkScreen.set(null)
        enqueueRequest(mProductUuid.get(), true)
    }

    override fun deeplinkToScreen(identifier: DeepLinkIdentifier, params: Map<String, String>?) {
        showProgressAndDisableTouchPrivate.postValue(true)
        mPendingDeeplinkWorkflow.set(null)
        mPendingDeeplinkScreen.set(identifier)
        enqueueRequest(mProductUuid.get(), true)
    }

    private suspend fun syncAllCreditCardTrx(uuid: String) {
        if (isTrxSyncInProgress) return
        trxUseCases.syncAllCreditCardTrx(uuid).collect { isTrxSyncInProgress = false }
    }

    private suspend fun loadProductDetails(uuid: String, isLocal: Boolean) {
//        Log.d("CreditCardDetailsViewModelImpl", "loadProductDetails")
        productUseCases.getLocalCreditProduct(uuid)
            .xZip(
                trxUseCases.getLocalCreditCardTrxGraphQL(uuid, null, null),
                customerUseCases.getCurrentCustomerGraphQL()
            ) { productRes, trxRes, customerRes -> Triple(productRes.data, trxRes.data, customerRes.data) }
            .collect { productResult ->
                populateModel(
                    productResult.first,
                    productResult.second?.map { it.toTrxOverviewData() },
                    productResult.third,
                    isLocal
                )
            }
    }

    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    fun populateModel(res: CreditCardProductAndPaymentsModel?, trxes: List<CreditCardTrxOverview>?, customer: CustomerGraphQLModel?, isLocal: Boolean) {
        val creditProduct = res?.productModel ?: run {
            dismissPrivate.postValue(Unknown())
            return
        }
        if (!isLocal) {
            isLoadingInProgress.set(false)
            showProgressAndDisableTouchPrivate.postValue(false)
            currentRequestId.set(-1)
        }
        if (cancelRequests.get()) {
            return
        }
        titlePrivate.postValue(
            if (creditProduct.isMLS == true) {
                if (!creditProduct.cardLastFour.isNullOrBlank()) {
                    "MLS Forward\nCredit Card (• ${creditProduct.cardLastFour})"
                } else {
                    "MLS Forward\nCredit Card"
                }

            } else {
                if (!creditProduct.cardLastFour.isNullOrBlank()) {
                    "Credit Card (• ${creditProduct.cardLastFour})"
                } else {
                    "Credit Card"
                }
            }
        )
        val payments = res.paymentModels?.map { it.toPaymentOverviewData() }
        val lastPayment = res.paymentModels?.filter { it.date != null }?.maxByOrNull { it.date!! }?.toPaymentDetailData()
        topModelsPrivate.postValue(listOfNotNull(
            if (!creditProduct.wasClosed && lastPayment?.state == CreditCardPaymentStatus.DECLINED) {
                FeatureSimpleBannerHolder.Model(R.string.recent_payment_failed)
            } else null,
            CreditCardDetailsCardHolder.Model(
                lastFour = creditProduct.cardLastFour,
                isMLS = creditProduct.isMLS,
                isLocked = creditProduct.locked,
                isActivated = creditProduct.isActive,
                owner = customer?.fullName,
                isHidden = false,
            ),
            if (creditProduct.isCardActivatable) {
                FeatureMenuSimpleHolder.Model(
                    imageID = R.drawable.ic_card,
                    titleID = R.string.activate_card_text,
                    hideToggle = true,
                    hideTopDivider = false,
                    hideBottomDivider = true,
                    hideIndicator = false,
                    disableIndicator = creditProduct.isSoldOff,
                    itemClickAction = { view -> startWorkflow(view, creditProduct.uuid, CREDIT.raw, ACTIVATE_CARD.key, R.string.activate_card_text) },
                    itemContentDescription = credit_card_activate_card_button
                )
            } else null,
            FeatureMenuSimpleHolder.Model(
                imageID = if (creditProduct.locked == true) R.drawable.ic_unlocked else R.drawable.ic_lock,
                titleID = if (creditProduct.locked == true) R.string.unlock_card_text else R.string.lock_card_text,
                hideTopDivider = false,
                hideBottomDivider = false,
                hideIndicator = false,
                disableIndicator = creditProduct.isSoldOff,
                itemClickAction = { view -> startWorkflow(view, creditProduct.uuid, CREDIT.raw, MANAGE_CARD_LOCK.key, R.string.lock_card_text) },
                itemContentDescription = credit_card_lock_card_button
            ),
        )
        )
        bottomModelsPrivate.postValue(listOfNotNull(
            CreditCardDetailsAmountHolder.Model(
                pendingAmountDisplay = creditProduct.currentBalanceDisplay,
                availableAmountDisplay = creditProduct.availableTotalCreditDisplay,
                settlementAmountDisplay = customer?.settlementAmountDueRemainingDisplay,
                displayStatus = creditProduct.displayStatus,
                isSoldOff = creditProduct.isSoldOff
            ),
            QuickActionMenuHolder.Model(
                menu1 = MenuData(R.string.make_payment, R.drawable.ic_show_card, disable = creditProduct.isSoldOff, credit_card_make_payment_button) { view -> startWorkflow(view, creditProduct.uuid, CREDIT.raw,  MAKE_CARD_PAYMENT.key, R.string.make_payment_title) },
//                menu2 = MenuData(R.string.all_transactions_text_2, R.drawable.ic_view_statements) { navigationDirectionPrivate.postValue(actionGlobalToCreditCardTrxListDeprecatedFragment(product.productUuid)) },
                menu2 = MenuData(R.string.statements_text, R.drawable.ic_view_statements, disable = false, credit_card_statements_button) { navigationDirectionPrivate.postValue(actionGlobalToStatementListFragment(creditProduct.uuid, creditProduct.cardLastFour)) },
                menu3 = MenuData(R.string.payment, R.drawable.ic_clock_three, disable = creditProduct.isSoldOff, credit_card_payment_button) { navigationDirectionPrivate.postValue(actionGlobalToPaymentHistoryFragment(creditProduct.uuid, CREDIT_CARD)) },
                moreMenuClickAction = { navigationDirectionPrivate.postValue(actionGlobalToMoreActionsMenuFragment(creditProduct.uuid, creditProduct.isSoldOff, canManageCard = customer?.canManageDebitCard ?: false)) },
                moreMenuContentDescription = credit_card_more_actions_button
            ),
            if (creditProduct.isCardActivatable) {
                FeatureSimpleButtonHolder.Model(R.string.activate_card) { view ->
                    startWorkflow(view, creditProduct.uuid, CREDIT.raw, ACTIVATE_CARD.key, R.string.activate_card_text)
                }
            } else null,
            if (!creditProduct.wasClosed && !creditProduct.isSoldOff) {
                val lastPayment = res.paymentModels?.filter { it.date != null }?.maxByOrNull { it.date!! }?.toPaymentDetailData()
                val pendingPayment = res.paymentModels?.filter { CreditCardPaymentStatus.createFrom(it.status) == CreditCardPaymentStatus.PENDING }?.maxByOrNull { it.date!! }?.toPaymentDetailData()
                val scheduledPaymentsCount = res.paymentModels?.filter { CreditCardPaymentStatus.createFrom(it.status) == CreditCardPaymentStatus.SCHEDULED }?.size ?: 0
                CreditCardPaymentDetailsHolder.Model(
                    uuid = creditProduct.uuid,
                    isClosed = creditProduct.wasClosed,
                    isAutoPay = creditProduct.autopayActive ?: false,
                    isPastDue = creditProduct.pastDue ?: false,
                    lastFour = creditProduct.cardLastFour,
                    isSold = creditProduct.isSoldOff,
                    currentBalanceAmount = creditProduct.currentBalance,
                    currentBalanceAmountDisplay = creditProduct.currentBalanceDisplay,
                    statementBalanceAmount = creditProduct.lastStatementBalanceAmount,
                    statementBalanceAmountDisplay = creditProduct.lastStatementBalanceDisplay,
                    minimumPaymentAmount = creditProduct.adjustedMinimumPaymentDueAmount,
                    minimumPaymentAmountDisplay = creditProduct.adjustedMinimumPaymentDueDisplay,
                    minimumPaymentDueDate = creditProduct.minimumPaymentDueDate.xToDate(),
                    scheduledPaymentsCount = scheduledPaymentsCount,
                    lastPayment = lastPayment,
                    pendingPayment = pendingPayment,
                    isOverLimit = creditProduct.overLimit,
                    baseUrlGraphQL = prefsManager.baseUrlGraphQL,
                    paymentProtection = creditProduct.paymentProtectionStatus,
                    paymentProtectionSsoPath = creditProduct.paymentProtectionSsoPath,
                )
            } else null,
            if (creditProduct.isMLS) {
                FeatureSimpleCTAHolder.Model(
                    titleID = R.string.mls_rewards,
                    subtitleID = R.string.mls_rewards_description,
                    imageID = R.drawable.ic_chalice,
                    actionID = R.string.redeem_points,
                    action = { launchExternalUrlPrivate.postValue("https://mlsrewards.avant.com") }
                )
            } else {
                val lifetimeRewardsInCents = creditProduct.lifeTimeRewards?.xToCents() ?: 0
                val pendingRewardsInCents = creditProduct.currentCycleRewards?.xToCents() ?: 0
                if (lifetimeRewardsInCents > 0 || pendingRewardsInCents > 0) {
                    CreditCardCashBackRewardsHolder.Model(
                        lifetimeEarnedDisplayAmount = "$${lifetimeRewardsInCents.xDollarCentsCurrencyString()}",
                        pendingCashBackDisplayAmount = "$${pendingRewardsInCents.xDollarCentsCurrencyString()}",
                        tipAction = {
                            showBottomDialogPrivate.postValue(BottomDialogData(
                                DialogDataEntity(
                                    mBodyTextID = R.string.pending_cash_back_tips,
                                    mPrimaryButtonTextID = R.string.ok_text
                                )
                            ))
                        }
                    )
                } else null
            },
            CreditCardTrxOverviewHolder.Model(
                isLocal = isLocal,
                trxes = trxes?.take(5),
                filterAction = { showDateOptionsPrivate.postValue(dateOptions) },
                allTrxButtonClick = { navigationDirectionPrivate.postValue(actionGlobalToCreditCardTrxListDeprecatedFragment(creditProduct.uuid)) }
            ),
            if (!creditProduct.isSoldOff) {
                CreditCardPaymentOverviewHolder.Model(
                    isLocal = isLocal,
                    payments = payments?.filter {
                        it.state in setOf(
                            CreditCardPaymentStatus.SCHEDULED,
                            CreditCardPaymentStatus.PENDING,
                            CreditCardPaymentStatus.POSTED,
                            CreditCardPaymentStatus.CANCELED,
                        )
                    }?.sortedByDescending {it.date}?.take(5),
                    trxClickAction = { payment -> xHandleCreditPaymentClickAction(payment)},
                    allTrxButtonClick = {
                        navigationDirectionPrivate.postValue(actionGlobalToCreditCardTrxListFragment(creditProduct.uuid))
                    }
                )
            } else { null }
        ))
        if (!isLocal) {
            checkPendingWorkflow()
            checkPendingScreen(creditProduct.cardLastFour)
        }
    }

    @VisibleForTesting(otherwise = VisibleForTesting.PRIVATE)
    fun populateLoadingModelIfNeeded(product: CreditCardProductAndPaymentsModel?, trxes: List<CreditCardTrxOverview>?, customer: CustomerGraphQLModel?, isLocal: Boolean) {
        if (product == null) {
            topModelsPrivate.postValue(listOf(
                CreditCardLoadingHolder.Model(),
            ))
            bottomModelsPrivate.postValue(listOf(
                CreditCardDetailsLoadingHolder.Model(),
            ))
            return
        }
        isLoaded.set(true)
        populateModel(product, trxes, customer, isLocal)
    }

    fun onDateSelected(option: OptionEntity, productUuid: String?) {
        navigationDirectionPrivate.postValue(
            actionGlobalToCreditCardTrxListDeprecatedFragment(
                productUuid = productUuid,
                statement = option.key
            )
        )
    }

    private fun checkPendingWorkflow() {
        if (mPendingDeeplinkWorkflow.get() == null || mProductUuid.get().isNullOrBlank()) return
        val workflowData = mPendingDeeplinkWorkflow.get()
        startWorkflowPrivate.postValue(Triple(
            workflowData.third,
            StartWorkflowData(
                productUuid = mProductUuid.get(),
                productType = workflowData.second.raw,
                workflowName = workflowData.first.key,
                extraParams = mapOf()),
            workflowData.second
        ))
        mPendingDeeplinkWorkflow.set(null)
    }

    private fun checkPendingScreen(accountLastFour: String?) {
        if (mPendingDeeplinkScreen.get() == null || mProductUuid.get().isNullOrBlank()) return
        val identifier = mPendingDeeplinkScreen.get()
        deeplinkNavigationPrivate.postValue(Triple(mProductUuid.get(), identifier, accountLastFour))
        mPendingDeeplinkScreen.set(null)
    }
}
