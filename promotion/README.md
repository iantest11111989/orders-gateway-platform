# Automatic promotion: the pause switch

Patch-only promotion PRs (`promote/staging`, `promote/prod`) are merged by the in-cluster patch promoter once the environment before has soaked for an hour with its SLO met.

**To pause all automatic promotion,** commit an empty file `promotion/PAUSED` to main. **To resume,** delete it. The next pass (every 10 minutes) picks the change up. While paused, promotion PRs stay open, and their promoter comment says why.

Promotions that ship a feature never merge on their own, paused or not: they need the owner's approval.
