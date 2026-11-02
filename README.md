# Rocket League Mafia

A free, browser-based companion for playing Rocket League Mafia.

## Status

This repository currently contains the first front-end prototype. It is **not yet a real multiplayer game**: players, roles, votes, and scores are local demo data. Do not use it as the authoritative game for a group yet.

## Preview locally

Open `index.html` in a browser, or enable GitHub Pages in the repository settings after the first commit.

## Planned free architecture

- **GitHub Pages** for static hosting.
- **Supabase Free** for room data, realtime updates, and secure game actions.
- Anonymous player sessions so friends do not need to create accounts.
- Database-side authorization and scoring so players cannot read other players' secret roles/tasks or alter scores.

No Supabase service-role key will ever be placed in browser code.

## Artwork

Canva exports can be added later under `assets/cards/`:

- `imposter.png`
- `teammate.png`
- `task-imposter.png`
- `task-teammate.png`

Portrait cards around a 2:3 ratio are a good starting point. The UI will use fallback styling until the images are added.

## Current rule defaults

**Teammate**
- Complete secret task: +3
- Win match: +2
- If the imposter is correctly identified by a unique majority: +2

**Imposter**
- Lose match: +5
- Complete secret task: +3
- If the vote has a unique incorrect majority and the imposter voted with that majority (not for themselves): +2
- If correctly identified, loses the +5 match-loss points

A tie awards no voting points and no imposter majority-alignment bonus.

All values should be configurable in the lobby. The production implementation will enforce these rules in trusted database functions.
