import Combine
import UIKit
import Gridicons
import Yosemite
import WordPressUI
import SafariServices
import SwiftUI
import WooFoundation

private typealias SyncReason = OrderListSyncActionUseCase.SyncReason

protocol OrderListViewControllerDelegate: AnyObject {
    /// Called when `OrderListViewController` (or `OrdersViewController`) is about to fetch Orders from the API.
    ///
    func orderListViewControllerWillSynchronizeOrders(_ viewController: UIViewController)

    /// Called when an order list `UIScrollView`'s `scrollViewDidScroll` event is triggered from the user.
    ///
    func orderListScrollViewDidScroll(_ scrollView: UIScrollView)

    /// Called when a user press a clear filters button. Eg. the clear filters button in the empty screen.
    ///
    func clearFilters()
}

/// OrderListViewController: Displays the list of Orders associated to the active Store / Account.
///
final class OrderListViewController: UIViewController, GhostableViewController {

    weak var delegate: OrderListViewControllerDelegate?

    private let viewModel: OrderListViewModel

    /// Main TableView.
    ///
    @IBOutlet weak var tableView: UITableView!

    /// The data source that is bound to `tableView`.
    private lazy var dataSource: UITableViewDiffableDataSource<String, FetchResultSnapshotObjectID> = {
        let dataSource = UITableViewDiffableDataSource<String, FetchResultSnapshotObjectID>(
            tableView: self.tableView,
            cellProvider: self.makeCellProvider()
        )
        dataSource.defaultRowAnimation = .fade
        return dataSource
    }()

    lazy var ghostTableViewController = GhostTableViewController(options: GhostTableViewOptions(cellClass: OrderTableViewCell.self,
                                                                                                estimatedRowHeight: Settings.estimatedRowHeight,
                                                                                                tableViewStyle: .grouped,
                                                                                                isScrollEnabled: false))

    /// Pull To Refresh Support.
    ///
    private lazy var refreshControl: UIRefreshControl = {
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(pullToRefresh(sender:)), for: .valueChanged)
        return refreshControl
    }()

    /// Footer "Loading More" Spinner.
    ///
    private lazy var footerSpinnerView = FooterSpinnerView()

    /// The view shown if the list is empty.
    ///
    private lazy var emptyStateViewController = EmptyStateViewController(style: .list)

    /// SyncCoordinator: Keeps tracks of which pages have been refreshed, and encapsulates the "What should we sync now" logic.
    ///
    private let syncingCoordinator = SyncingCoordinator()

    /// Timestamp for last successful sync.
    ///
    private var lastFullSyncTimestamp: Date?

    /// Minimum time interval allowed between full sync.
    ///
    private let minimalIntervalBetweenSync: TimeInterval = 30

    /// UI Active State
    ///
    private var state: State = .results {
        didSet {
            guard oldValue != state else {
                return
            }

            didLeave(state: oldValue)
            didEnter(state: state)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private let siteID: Int64

    /// Current top banner that is displayed.
    ///
    private var topBannerView: UIView?

    /// Callback closure when an order is selected
    ///
    private var switchDetailsHandler: (OrderDetailsViewModel?) -> Void

    /// Currently selected index path in the table view
    ///
    private var selectedIndexPath: IndexPath?

    /// Currently selected order ID in the table view
    ///
    private var selectedOrderID: Int64?

    private lazy var isSplitViewInOrdersTabEnabled: Bool = ServiceLocator.featureFlagService.isFeatureFlagEnabled(.splitViewInOrdersTab)

    /// Tracks if the swipe actions have been glanced to the user.
    ///
    private var swipeActionsGlanced = false

    /// Banner variation that will be shown as In-Person Payments feedback banner. If any.
    ///
    private var inPersonPaymentsSurveyVariation: SurveyViewController.Source?


    // MARK: - View Lifecycle

    /// Designated initializer.
    ///
    init(siteID: Int64,
         title: String,
         viewModel: OrderListViewModel,
         switchDetailsHandler: @escaping (OrderDetailsViewModel?) -> Void) {
        self.siteID = siteID
        self.viewModel = viewModel
        self.switchDetailsHandler = switchDetailsHandler

        super.init(nibName: type(of: self).nibName, bundle: nil)

        self.title = title
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("Not supported")
    }

    deinit {
        cancellables.forEach {
            $0.cancel()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        registerUserActivity()

        registerTableViewHeadersAndCells()
        configureTableView()

        configureViewModel()
        configureSyncingCoordinator()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        syncingCoordinator.resynchronize(reason: SyncReason.viewWillAppear.rawValue)

        // Fix any incomplete animation of the refresh control
        // when switching tabs mid-animation
        refreshControl.resetAnimation(in: tableView)

        // Fix any _incomplete_ animation if the orders were deleted and refetched from
        // a different location (or Orders tab).
        //
        // We can remove this once we've replaced XLPagerTabStrip.
        tableView.reloadData()

        viewModel.updateBannerVisibility()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.updateHeaderHeight()
    }

    override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransition(to: newCollection, with: coordinator)
        if isSplitViewInOrdersTabEnabled, selectedIndexPath != nil {
            // Reload table view to update selected state on the list when changing rotation
            tableView.reloadData()
        }
    }

    /// Returns a function that creates cells for `dataSource`.
    private func makeCellProvider() -> UITableViewDiffableDataSource<String, FetchResultSnapshotObjectID>.CellProvider {
        return { [weak self] tableView, indexPath, objectID in
            let cell = tableView.dequeueReusableCell(OrderTableViewCell.self, for: indexPath)
            guard let self = self else {
                return cell
            }

            let cellViewModel = self.viewModel.cellViewModel(withID: objectID)

            cell.configureCell(viewModel: cellViewModel)
            cell.layoutIfNeeded()
            return cell
        }
    }
}


// MARK: - User Interface Initialization
//
private extension OrderListViewController {
    /// Initialize ViewModel operations
    ///
    func configureViewModel() {
        viewModel.onShouldResynchronizeIfViewIsVisible = { [weak self] in
            guard let self = self,
                  // Avoid synchronizing if the view is not visible. The refresh will be handled in
                  // `viewWillAppear` instead.
                  self.viewIfLoaded?.window != nil else {
                return
            }

            self.syncingCoordinator.resynchronize()
        }

        viewModel.onShouldResynchronizeIfNewFiltersAreApplied = { [weak self] in
            self?.syncingCoordinator.resynchronize(reason: SyncReason.newFiltersApplied.rawValue)
        }

        viewModel.activate()

        /// Update the `dataSource` whenever there is a new snapshot.
        viewModel.snapshot.sink { [weak self] snapshot in
            guard let self = self else { return }
            self.dataSource.apply(snapshot)

            if self.isSplitViewInOrdersTabEnabled, self.splitViewController?.isCollapsed == false {
                self.checkSelectedItem()
            }

        }.store(in: &cancellables)

        /// Update the top banner when needed
        viewModel.$topBanner
            .sink { [weak self] topBannerType in
                guard let self = self else { return }
                switch topBannerType {
                case .none:
                    self.hideTopBannerView()
                case .error:
                    self.setErrorTopBanner()
                case .orderCreation:
                    self.setOrderCreationTopBanner()
                case .inPersonPaymentsFeedback(let survey):
                    if self.inPersonPaymentsSurveyVariation != survey {
                        self.inPersonPaymentsSurveyVariation = survey
                        self.viewModel.trackInPersonPaymentsFeedbackBannerShown(for: survey)
                    }
                    self.setIPPFeedbackTopBanner(survey: survey)
                }
            }
            .store(in: &cancellables)
    }

    /// Setup: Sync'ing Coordinator
    ///
    func configureSyncingCoordinator() {
        syncingCoordinator.delegate = self
    }

    /// Setup: TableView
    ///
    func configureTableView() {
        tableView.delegate = self
        tableView.dataSource = dataSource

        view.backgroundColor = .listBackground
        tableView.accessibilityIdentifier = "orders-table-view"
        tableView.backgroundColor = .listBackground
        tableView.refreshControl = refreshControl
        tableView.tableFooterView = footerSpinnerView
        tableView.estimatedSectionHeaderHeight = Settings.estimatedHeaderHeight
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.sectionFooterHeight = .leastNonzeroMagnitude
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = UITableView.automaticDimension
    }

    /// Registers all of the available table view cells and headers
    ///
    func registerTableViewHeadersAndCells() {
        tableView.registerNib(for: OrderTableViewCell.self)

        let headerType = TwoColumnSectionHeaderView.self
        tableView.register(headerType.loadNib(), forHeaderFooterViewReuseIdentifier: headerType.reuseIdentifier)
    }
}

// MARK: - Actions
//
extension OrderListViewController {
    @objc func pullToRefresh(sender: UIRefreshControl) {
        ServiceLocator.analytics.track(.ordersListPulledToRefresh)
        delegate?.orderListViewControllerWillSynchronizeOrders(self)
        NotificationCenter.default.post(name: .ordersBadgeReloadRequired, object: nil)
        syncingCoordinator.resynchronize(reason: SyncReason.pullToRefresh.rawValue) {
            sender.endRefreshing()
        }
    }

    private func markOrderAsCompleted(resultID: FetchResultSnapshotObjectID) {
        guard let orderDetailsViewModel = viewModel.detailsViewModel(withID: resultID) else {
            return DDLogError("⛔️ ViewModel for resultID: \(resultID) not found")
        }
        /// Actions that performs the mark completed request remotely.
        let fulfillmentProcess = orderDetailsViewModel.markCompleted(flow: .list)

        /// Messages configuration
        let noticeConfiguration = OrderFulfillmentNoticePresenter.NoticeConfiguration(
            successTitle: Localization.markCompletedNoticeTitle(orderID: orderDetailsViewModel.order.orderID),
            errorTitle: Localization.markCompletedErrorNoticeTitle(orderID: orderDetailsViewModel.order.orderID))

        /// Fires fulfillment action, observes its result and enqueue the appropriate notices.
        let presenter = OrderFulfillmentNoticePresenter(noticeConfiguration: noticeConfiguration)
        presenter.present(process: fulfillmentProcess)
    }

    /// Slightly reveal swipe actions of the first visible cell that contains at least one swipe action.
    /// This action is performed only once, using `swipeActionsGlanced` as a control variable.
    ///
    private func glanceTrailingActionsIfNeeded() {
        if !swipeActionsGlanced {
            swipeActionsGlanced = true
            tableView.glanceTrailingSwipeActions()
        }
    }
}

// MARK: - Sync'ing Helpers
//
extension OrderListViewController: SyncingCoordinatorDelegate {

    /// Synchronizes the Orders for the Default Store (if any).
    ///
    func sync(pageNumber: Int, pageSize: Int, reason: String? = nil, onCompletion: ((Bool) -> Void)? = nil) {
        if pageNumber == syncingCoordinator.pageFirstIndex,
           reason == SyncReason.viewWillAppear.rawValue,
           let lastFullSyncTimestamp = lastFullSyncTimestamp,
           Date().timeIntervalSince(lastFullSyncTimestamp) < minimalIntervalBetweenSync {
            // less than 30 s from last full sync
            onCompletion?(true)
            return
        }

        transitionToSyncingState()
        viewModel.hasErrorLoadingData = false
        viewModel.updateBannerVisibility()

        let action = viewModel.synchronizationAction(
            siteID: siteID,
            pageNumber: pageNumber,
            pageSize: pageSize,
            reason: SyncReason(rawValue: reason ?? "")) { [weak self] totalDuration, error in
                guard let self = self else {
                    return
                }

                if let error = error {
                    ServiceLocator.analytics.track(event: .ordersListLoadError(error))
                    DDLogError("⛔️ Error synchronizing orders: \(error)")
                    self.viewModel.hasErrorLoadingData = true
                } else {
                    if pageNumber == self.syncingCoordinator.pageFirstIndex {
                        // save timestamp of last successful update
                        self.lastFullSyncTimestamp = Date()
                    }
                    ServiceLocator.analytics.track(event: .ordersListLoaded(totalDuration: totalDuration,
                                                                            pageNumber: pageNumber,
                                                                            filters: self.viewModel.filters))
                }

                self.transitionToResultsUpdatedState()
                onCompletion?(error == nil)
        }

        ServiceLocator.stores.dispatch(action)
    }

    /// Sets the current top banner in the table view header
    ///
    private func showTopBannerView() {
        guard let topBannerView = topBannerView else { return }

        // Configure header container view
        let headerContainer = UIView(frame: CGRect(x: 0, y: 0, width: Int(tableView.frame.width), height: 0))
        headerContainer.addSubview(topBannerView)
        headerContainer.pinSubviewToAllEdges(topBannerView)

        tableView.tableHeaderView = headerContainer
        tableView.updateHeaderHeight()
    }

    /// Hide the top banner from the table view header
    ///
    private func hideTopBannerView() {
        topBannerView?.removeFromSuperview()
        topBannerView = nil
        if tableView.tableHeaderView != nil {
            // Setting tableHeaderView = nil when having a previous value keeps an extra header space (See p5T066-3c3#comment-12307)
            // This solution avoids it by adding an almost zero height header (Originally from https://stackoverflow.com/a/18938763/428353)
            tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.size.width, height: CGFloat.leastNonzeroMagnitude))
        }

        tableView.updateHeaderHeight()
    }
}

// MARK: - Spinner Helpers
//
extension OrderListViewController {

    /// Starts the Footer Spinner animation, whenever `mustStartFooterSpinner` returns *true*.
    ///
    private func ensureFooterSpinnerIsStarted() {
        guard mustStartFooterSpinner() else {
            return
        }

        footerSpinnerView.startAnimating()
    }

    /// Whenever we're sync'ing an Orders Page that's beyond what we're currently displaying, this method will return *true*.
    ///
    private func mustStartFooterSpinner() -> Bool {
        guard let highestPageBeingSynced = syncingCoordinator.highestPageBeingSynced else {
            return false
        }

        return highestPageBeingSynced * SyncingCoordinator.Defaults.pageSize > dataSource.numberOfItems
    }

    /// Stops animating the Footer Spinner.
    ///
    private func ensureFooterSpinnerIsStopped() {
        footerSpinnerView.stopAnimating()
    }
}

// MARK: - Split view helpers
//
private extension OrderListViewController {
    /// Highlights the selected row if any row has been selected and the split view is not collapsed.
    /// Removes the selected state otherwise.
    ///
    func highlightSelectedRowIfNeeded() {
        guard let selectedIndexPath = selectedIndexPath else {
            return
        }
        if splitViewController?.isCollapsed == true {
            tableView.deselectRow(at: selectedIndexPath, animated: false)
        } else {
            tableView.selectRow(at: selectedIndexPath, animated: false, scrollPosition: .none)
        }
    }

    /// Checks to see if the selected item is still at the same index in the list and resets its state if not.
    ///
    func checkSelectedItem() {
        guard let indexPath = selectedIndexPath, let orderID = selectedOrderID else {
            return selectFirstItemIfPossible()
        }

        guard let objectID = dataSource.itemIdentifier(for: indexPath),
            let orderDetailsViewModel = viewModel.detailsViewModel(withID: objectID) else {
            return selectFirstItemIfPossible()
        }

        if orderDetailsViewModel.order.orderID != orderID {
            selectFirstItemIfPossible()
        }
    }

    /// Attempts setting the first item in the list as selected if there's any item at all.
    /// Otherwise, triggers closure to remove the current selected item from the split view's secondary column.
    ///
    func selectFirstItemIfPossible() {
        let firstIndexPath = IndexPath(row: 0, section: 0)
        guard let objectID = dataSource.itemIdentifier(for: firstIndexPath),
              let orderDetailsViewModel = viewModel.detailsViewModel(withID: objectID),
                state != .empty else {
            selectedOrderID = nil
            selectedIndexPath = nil
            return switchDetailsHandler(nil)
        }
        selectedOrderID = orderDetailsViewModel.order.orderID
        selectedIndexPath = firstIndexPath
        switchDetailsHandler(orderDetailsViewModel)
        highlightSelectedRowIfNeeded()
    }
}


// MARK: - Placeholders & Ghostable Table
//
private extension OrderListViewController {

    /// Renders the Placeholder Orders
    ///
    func displayPlaceholderOrders() {
        displayGhostContent()
    }

    /// Removes the Placeholder Orders (and restores the ResultsController <> UITableView link).
    ///
    func removePlaceholderOrders() {
        removeGhostContent()
    }
}

// MARK: - Empty state view configuration
//
private extension OrderListViewController {
    /// Shows the EmptyStateViewController
    ///
    func displayEmptyViewController() {
        let childController = emptyStateViewController

        // Abort if we are already displaying this childController
        guard childController.parent == nil else {
            return
        }
        guard let childView = childController.view else {
            return
        }

        childController.configure(createFilterConfig())

        // Show Error Loading Data banner if the empty state is caused by a sync error
        if viewModel.hasErrorLoadingData {
            childController.showTopBannerView()
        } else {
            childController.hideTopBannerView()
        }

        childView.translatesAutoresizingMaskIntoConstraints = false

        addChild(childController)
        view.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            childView.topAnchor.constraint(equalTo: tableView.topAnchor),
            childView.bottomAnchor.constraint(equalTo: tableView.bottomAnchor)
        ])
        childController.didMove(toParent: self)
    }

    func removeEmptyViewController() {
        let childController = emptyStateViewController

        guard childController.parent == self,
            let childView = childController.view else {
            return
        }

        childController.willMove(toParent: nil)
        childView.removeFromSuperview()
        childController.removeFromParent()
    }

    /// Empty state config
    ///
    func createFilterConfig() ->  EmptyStateViewController.Config {
        guard let filters = viewModel.filters, filters.numberOfActiveFilters != 0 else {
            return noOrdersAvailableConfig()
        }

        return noOrdersMatchFilterConfig()
    }

    /// Creates EmptyStateViewController.Config when there are no orders available
    ///
    func noOrdersAvailableConfig() -> EmptyStateViewController.Config {
        .withLink(message: NSAttributedString(string: Localization.allOrdersEmptyStateMessage),
                  image: .emptyOrdersImage,
                  details: Localization.allOrdersEmptyStateDetail,
                  linkTitle: Localization.learnMore,
                  linkURL: WooConstants.URLs.blog.asURL()) { [weak self] refreshControl in
            self?.pullToRefresh(sender: refreshControl)
        }
    }

    /// Creates EmptyStateViewController.Config for no orders matching the filter empty view
    ///
    func noOrdersMatchFilterConfig() -> EmptyStateViewController.Config {
        let boldSearchKeyword = NSAttributedString(string: viewModel.filters?.readableString ?? String(),
                                                   attributes: [.font: EmptyStateViewController.Config.messageFont.bold])
        let message = NSMutableAttributedString(string: Localization.filteredOrdersEmptyStateMessage)
        message.replaceFirstOccurrence(of: "%@", with: boldSearchKeyword)

        return EmptyStateViewController.Config.withButton(
            message: message,
            image: .emptySearchResultsImage,
            details: "",
            buttonTitle: Localization.clearButton,
            onTap: { [weak self] button in
                self?.delegate?.clearFilters()
            },
            onPullToRefresh: { [weak self] refreshControl in
                self?.pullToRefresh(sender: refreshControl)
            })
    }
}

// MARK: - UITableViewDelegate Conformance
//
extension OrderListViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if splitViewController?.isCollapsed == true || !isSplitViewInOrdersTabEnabled {
            tableView.deselectRow(at: indexPath, animated: true)
        }

        guard state != .placeholder else {
            return
        }

        guard let objectID = dataSource.itemIdentifier(for: indexPath),
            let orderDetailsViewModel = viewModel.detailsViewModel(withID: objectID) else {
                return
        }

        selectedIndexPath = indexPath
        let order = orderDetailsViewModel.order
        ServiceLocator.analytics.track(event: WooAnalyticsEvent.Orders.orderOpen(order: order))
        selectedOrderID = order.orderID

        if isSplitViewInOrdersTabEnabled {
            switchDetailsHandler(orderDetailsViewModel)
        } else {
            let viewController = OrderDetailsViewController(viewModel: orderDetailsViewModel)
            navigationController?.pushViewController(viewController, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let itemIndex = dataSource.indexOfItem(for: indexPath) else {
            return
        }

        syncingCoordinator.ensureNextPageIsSynchronized(lastVisibleIndex: itemIndex)
        if isSplitViewInOrdersTabEnabled, indexPath == selectedIndexPath {
            highlightSelectedRowIfNeeded()
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let reuseIdentifier = TwoColumnSectionHeaderView.reuseIdentifier
        guard let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: reuseIdentifier) as? TwoColumnSectionHeaderView else {
            return nil
        }

        header.leftText = {
            guard let sectionIdentifier = dataSource.sectionIdentifier(for: section) else {
                return nil
            }

            return viewModel.sectionTitleFor(sectionIdentifier: sectionIdentifier)
        }()
        header.rightText = nil

        return header
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        delegate?.orderListScrollViewDidScroll(scrollView)
    }

    /// Provide an implementation to show cell swipe actions. Return `nil` to provide no action.
    ///
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        /// Fetch the order view model and make sure the order is not marked as completed before proceeding.
        ///
        guard let objectID = dataSource.itemIdentifier(for: indexPath),
              let cellViewModel = viewModel.cellViewModel(withID: objectID),
              cellViewModel.status != .completed else {
                  return nil
              }
        let markAsCompletedAction = UIContextualAction(style: .normal, title: Localization.markCompleted, handler: { [weak self] _, _, completionHandler in
            self?.markOrderAsCompleted(resultID: objectID)
            completionHandler(true) // Tells the table that the action was performed and forces it to go back to its original state (un-swiped)
        })
        markAsCompletedAction.backgroundColor = .brand
        markAsCompletedAction.image = .checkmarkImage

        return UISwipeActionsConfiguration(actions: [markAsCompletedAction])
    }
}

// MARK: - Finite State Machine Management
//
private extension OrderListViewController {

    func didEnter(state: State) {
        switch state {
        case .empty:
            displayEmptyViewController()
        case .placeholder:
            displayPlaceholderOrders()
        case .syncing:
            ensureFooterSpinnerIsStarted()
        case .results:
            glanceTrailingActionsIfNeeded()
        }
    }

    func didLeave(state: State) {
        switch state {
        case .empty:
            removeEmptyViewController()
        case .placeholder:
            removePlaceholderOrders()
        case .syncing:
            ensureFooterSpinnerIsStopped()
        case .results:
            break
        }
    }

    /// Should be called before Sync'ing. Transitions to either `results` or `placeholder` state, depending on whether if
    /// we've got cached results, or not.
    ///
    func transitionToSyncingState() {
        state = dataSource.isEmpty ? .placeholder : .syncing
    }

    /// Should be called whenever the results are updated: after Sync'ing (or after applying a filter).
    /// Transitions to `.results` or `.empty`.
    ///
    func transitionToResultsUpdatedState() {
        state = dataSource.isEmpty ? .empty : .results
    }
}

// MARK: Top Banner Factories
private extension OrderListViewController {
    /// Sets the `topBannerView` property to an error banner.
    ///
    func setErrorTopBanner() {
        topBannerView = ErrorTopBannerFactory.createTopBanner(isExpanded: false, expandedStateChangeHandler: { [weak self] in
            self?.tableView.updateHeaderHeight()
        },
        onTroubleshootButtonPressed: { [weak self] in
            guard let self = self else { return }

            WebviewHelper.launch(WooConstants.URLs.troubleshootErrorLoadingData.asURL(), with: self)
        },
        onContactSupportButtonPressed: { [weak self] in
            guard let self = self else { return }
            let supportForm = SupportFormHostingController(viewModel: .init())
            supportForm.show(from: self)
        })
        showTopBannerView()
    }

    /// Sets the `topBannerView` property to an orders banner.
    ///
    func setOrderCreationTopBanner() {
        topBannerView = OrdersTopBannerFactory.createOrdersBanner(onTopButtonPressed: { [weak self] in
            self?.tableView.updateHeaderHeight()
        }, onDismissButtonPressed: { [weak self] in
            self?.viewModel.dismissOrdersBanner()
        }, onGiveFeedbackButtonPressed: { [weak self] in
            let surveyNavigation = SurveyCoordinatingController(survey: .orderCreation)
            self?.present(surveyNavigation, animated: true, completion: nil)
        })
        showTopBannerView()
    }

    /// Sets the `topBannerView` property to an IPP feedback banner.
    ///
    func setIPPFeedbackTopBanner(survey: SurveyViewController.Source) {
        topBannerView = createIPPFeedbackTopBanner(survey: survey)
        showTopBannerView()
    }

    private func createIPPFeedbackTopBanner(survey: SurveyViewController.Source) -> TopBannerView {
        var bannerTitle = ""
        var bannerText = ""
        var campaign: FeatureAnnouncementCampaign = .inPersonPaymentsCashOnDelivery

        switch survey {
        case .inPersonPaymentsCashOnDelivery :
            bannerTitle = Localization.inPersonPaymentsCashOnDeliveryBannerTitle
            bannerText = Localization.inPersonPaymentsCashOnDeliveryBannerContent
            campaign = .inPersonPaymentsCashOnDelivery
        case .inPersonPaymentsFirstTransaction:
            bannerTitle = Localization.inPersonPaymentsFirstTransactionBannerTitle
            bannerTitle = Localization.inPersonPaymentsFirstTransactionBannerContent
            campaign = .inPersonPaymentsFirstTransaction
        case .inPersonPaymentsPowerUsers:
            bannerTitle = Localization.inPersonPaymentsPowerUsersBannerTitle
            bannerTitle = Localization.inPersonPaymentsPowerUsersBannerContent
            campaign = .inPersonPaymentsPowerUsers
        default:
            break
        }

        let shareIPPFeedbackAction = TopBannerViewModel.ActionButton(title: Localization.shareFeedbackButton, action: { [weak self] _ in
            self?.displayIPPFeedbackBannerSurvey(survey: survey)
            self?.viewModel.IPPFeedbackBannerCTATapped(for: campaign)
            self?.viewModel.IPPFeedbackBannerWasSubmitted()
        })

        let viewModel = TopBannerViewModel(
            title: bannerTitle,
            infoText: bannerText,
            icon: UIImage.commentContent,
            isExpanded: true,
            topButton: .dismiss(handler: {
                self.showIPPFeedbackDismissAlert(survey: survey, campaign: campaign)
            }),
            actionButtons: [shareIPPFeedbackAction]
        )
        let topBannerView = TopBannerView(viewModel: viewModel)
        topBannerView.translatesAutoresizingMaskIntoConstraints = false
        return topBannerView
    }

    private func displayIPPFeedbackBannerSurvey(survey: SurveyViewController.Source) {
        let surveyNavigation = SurveyCoordinatingController(survey: survey)
        self.present(surveyNavigation, animated: true, completion: nil)
    }

    private func showIPPFeedbackDismissAlert(survey: SurveyViewController.Source, campaign: FeatureAnnouncementCampaign ) {
        let actionSheet = UIAlertController(
            title: Localization.dismissTitle,
            message: Localization.dismissMessage,
            preferredStyle: .alert
        )

        let remindMeLaterAction = UIAlertAction( title: Localization.remindMeLater, style: .default) { [weak self] _ in
            self?.viewModel.IPPFeedbackBannerRemindMeLaterTapped(for: campaign)
        }
        actionSheet.addAction(remindMeLaterAction)

        let dontShowAgainAction = UIAlertAction( title: Localization.dontShowAgain, style: .default) { [weak self] _ in
            self?.viewModel.IPPFeedbackBannerDontShowAgainTapped(for: campaign)
        }
        actionSheet.addAction(dontShowAgainAction)

        self.present(actionSheet, animated: true)
    }
}

// MARK: - Constants
//
private extension OrderListViewController {
    enum Localization {
        static let allOrdersEmptyStateMessage = NSLocalizedString("Waiting for your first order",
                                                                  comment: "The message shown in the Orders → All Orders tab if the list is empty.")
        static let allOrdersEmptyStateDetail = NSLocalizedString("Explore how you can increase your store sales",
                                                                 comment: "The detailed message shown in the Orders → All Orders tab if the list is empty.")
        static let learnMore = NSLocalizedString("Learn more", comment: "Title of button shown in the Orders → All Orders tab if the list is empty.")
        static let filteredOrdersEmptyStateMessage = NSLocalizedString("We're sorry, we couldn't find any order that match %@",
                   comment: "Message for empty Orders filtered results. The %@ is a placeholder for the filters entered by the user.")
        static let clearButton = NSLocalizedString("Clear Filters",
                                 comment: "Action to remove filters orders on the placeholder overlay when no orders match the filter on the Order List")

        static let markCompleted = NSLocalizedString("Mark Completed", comment: "Title for the swipe order action to mark it as completed")

        static let inPersonPaymentsCashOnDeliveryBannerTitle = NSLocalizedString("Let us know how we can help",
                                                           comment: "Title of the In-Person Payments feedback banner in the Orders tab"
        )

        static let inPersonPaymentsFirstTransactionBannerTitle = NSLocalizedString("Enjoyed your in-person payment?",
                                                            comment: "Title of the In-Person Payments feedback banner in the Orders tab"
        )

        static let inPersonPaymentsPowerUsersBannerTitle = NSLocalizedString("Let us know what you think",
                                                            comment: "Title of the In-Person Payments feedback banner in the Orders tab"
        )

        static let inPersonPaymentsCashOnDeliveryBannerContent = NSLocalizedString("Share your own experience or how you collect in-person payments.",
                                                             comment: "Content of the In-Person Payments feedback banner in the Orders tab"
        )

        static let inPersonPaymentsFirstTransactionBannerContent = NSLocalizedString("Rate your first in-person payment experience.",
                                                              comment: "Content of the In-Person Payments feedback banner in the Orders tab"
        )

        static let inPersonPaymentsPowerUsersBannerContent = NSLocalizedString("Tell us all about your experience with in-person payments.",
                                                              comment: "Content of the In-Person Payments feedback banner in the Orders tab"
        )

        static let shareFeedbackButton = NSLocalizedString("Share feedback",
                                                           comment: "Title of the feedback action button on the In-Person Payments feedback banner"
        )

        static let dismissTitle = NSLocalizedString("Give feedback",
                                                    comment: "Title of the modal confirmation screen when the In-Person Payments feedback banner is dismissed"
        )

        static let dismissMessage = NSLocalizedString("No worries! You can always go to Settings in the Menu to send us feedback.",
                    comment: "Message of the modal confirmation screen when the In-Person Payments feedback banner is dismissed")

        static let remindMeLater = NSLocalizedString("Remind me later",
                                                     comment: "Title of the button shown when the In-Person Payments feedback banner is dismissed."
        )

        static let dontShowAgain = NSLocalizedString("Don't show again",
                                                     comment: "Title of the button shown when the In-Person Payments feedback banner is dismissed."
        )

        static func markCompletedNoticeTitle(orderID: Int64) -> String {
            let format = NSLocalizedString(
                "Order #%1$d marked as completed",
                comment: "Notice title when an order is marked as completed via a swipe action. Parameter: Order Number"
            )
            return String.localizedStringWithFormat(format, orderID)
        }

        static func markCompletedErrorNoticeTitle(orderID: Int64) -> String {
            let format = NSLocalizedString(
                "Error updating Order #%1$d",
                comment: "Notice title when marking an order as completed via a swipe action fails. Parameter: Order Number"
            )
            return String.localizedStringWithFormat(format, orderID)
        }
    }

    enum Settings {
        static let estimatedHeaderHeight = CGFloat(43)
        static let estimatedRowHeight = CGFloat(86)
        static let placeholderRowsPerSection = [3]
    }

    enum State {
        case placeholder
        case syncing
        case results
        case empty
    }
}
