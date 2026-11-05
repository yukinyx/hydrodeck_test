enum PlantingNavigationPage { startContinue, dashboard }

class PlantingNavigationState {
  PlantingNavigationPage _page = PlantingNavigationPage.startContinue;

  PlantingNavigationPage get page => _page;

  void showDashboard() {
    _page = PlantingNavigationPage.dashboard;
  }

  void showStartContinue() {
    _page = PlantingNavigationPage.startContinue;
  }
}
