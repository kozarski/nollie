"""Crew tools for Nollie (the main profile) only."""


def register(ctx):
    if ctx.profile_name != "default":
        return
    from .crew import Crew
    from .hermes_profiles import HermesProfiles, caller
    from .tools import CrewTools
    profiles = HermesProfiles()
    CrewTools(Crew(profiles, profiles.home("default") / "nollie-crew"), caller).register(ctx)
