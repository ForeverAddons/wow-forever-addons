local addon, host = ...
host.ForeverCoreCopy = ForeverCoreLoader.Begin(addon, 1017002, "9e4bfedbcc5bc414b6de8b22aa1a468b2e62deec3f97f3912145b569b2c0c8bf", 38)
local offered, reason = ForeverCoreLoader.OfferStore(addon, "SkillRouteDB")
assert(offered or reason == "late", reason)
