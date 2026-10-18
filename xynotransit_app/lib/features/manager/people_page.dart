import 'package:flutter/material.dart';

import '../admin/people_screen.dart';
import '../shell/top_bar.dart';

/// The People section: teams, people and seats, under the manager top bar.
class PeoplePage extends StatelessWidget {
  const PeoplePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      appBar: TopBar(screen: Screen.people),
      body: PeopleScreenBody(),
    );
  }
}
