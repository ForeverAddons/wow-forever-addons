# SkillRoute

Profession levelling routes, skill-up chances and recipe costs in the WoW Forever Professions window,
priced with CraftCost's auction scans.

SkillRoute is a fork of [SkillUp Forever](https://github.com/cjber/skillup-forever) by cjber (GPL-3.0-or-later),
version 1.14.26. The window, route planner, shopping list, tracker, gear and buffs tabs, and the bundled
profession data are SkillUp Forever's. See [THIRD_PARTY.md](THIRD_PARTY.md) for the data sources and
[LICENSE](LICENSE) for the license.

## What's different from SkillUp Forever

- **CraftCost prices.** With CraftCost installed, its auction prices come first: its own scans, its deep-scan
  prices that ignore lowball listings, and the Auctionator prices it copies in. Auctionator, TradeSkillMaster, AHDB,
  Naowh Forever and Forever Ledger still fill any gaps. Pick another source in the settings.
- **Working Overtime multiplies the chance.** The Legacy talent's 4% per rank multiplies yellow and green skill-up
  chances (20% at 5/5), up to 100%. It's on by default and read from your Legacy tree.
- **The skill bar shows it.** In recipe tooltips and under the selected recipe, the orange band runs on to the last
  skill where a skill-up is still certain with your Working Overtime rank, and the "You" marker shows your chance,
  for example "You: 151 · 84%".

## Install

Copy the `SkillRoute` folder into `World of Warcraft\_forever_\Interface\AddOns\`, then disable SkillUp Forever
(both add the same pages to the Professions window). CraftCost is optional.

## Usage

Open a profession: the numbers are on each recipe, and the SkillRoute tab on the right of the Professions window
has the route, gear and buffs pages.

| Command | What it does |
|---|---|
| `/skillroute` | Open the settings (also Esc > Options > AddOns) |
| `/skillroute shopping` | Open the shopping list |
| `/skillroute skipped` | List recipes you said *Not this recipe* to; `/skillroute unskip <ID>` (or `all`) brings them back |
| `/skillroute trainers` | List the trainer skill requirements that were guessed, and which ones a trainer confirmed |
| `/skillroute audit` | Compare the bundled thresholds with the colours the game shows |
| `/skillroute report` | Show a report to copy into a bug report |

Report SkillRoute problems in this repository, not to SkillUp Forever.
