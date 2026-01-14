# Cooking Assistant — Design Spec

## Product Summary
A hands-free, voice-first cooking assistant that presents step-by-step visual and audio instructions in a slide-based “Cooking Mode.” It reduces touch interaction while cooking (greasy hands), lowers cognitive load, and coordinates timers and parallel steps.

## Target Users
- Intermediate home cooks who cook 3–5x/week
- Bakers and precision-focused cooks
- Multitaskers who want low-friction, hands-free guidance

## Problem Statements
- Touching and scrolling phones while cooking is messy and frustrating.
- Recipes are often vague about timing and quantities.
- Timers, instructions, and Q&A are fragmented across apps.

## Core Value Proposition
Hands-free, adaptive cooking guidance with large, readable visuals, clear audio pacing, and voice control that works in a real kitchen.

## Product Principles
- **Hands-free by default**: voice and auto-advance are the primary controls.
- **Distance readable**: large type, high contrast, 2–3m visibility.
- **Paced instruction**: audio tuned to real cooking tempo.
- **Adaptive detail**: skill level and equipment adjust the output.
- **Reliable timing**: integrated timers, alarms, and step hand-offs.

## Primary Flows
1. **Find a recipe**
   - Voice search (“show me garlic chicken”) or browse.
2. **Start Cooking Mode**
   - Step-by-step slides with optional audio narration.
3. **Hands-free control**
   - “Next step”, “repeat slower”, “skip”, “set timer for 10 minutes”.
4. **Timers and transitions**
   - Auto-advance when timer completes; alarm with audible prompt.
5. **In-context Q&A**
   - “How big is dice?” or “I only have an air fryer.”

## Key Screens
- **Home**: quick entry to recent recipes and voice search.
- **Recipe Detail**: ingredients, tools, estimated time, start button.
- **Cooking Mode**: full-screen slide view, large typography, audio status, timer strip.
- **Timer Overlay**: clear countdown with sound and vibration on completion.

## Voice UX
- Always-on push-to-talk in Cooking Mode.
- Short, deterministic commands for reliability.
- Clarification prompts only when necessary.

## Data Model (Draft)
- **Recipe**: id, title, cuisine, servings, ingredients[]
- **Step**: order, text, duration, audioText, timers[]
- **Timer**: label, duration, autoAdvance
- **UserPreferences**: skillLevel, unitSystem, equipment

## LLM + Cloudflare Worker (Draft)
- Worker receives raw recipe input.
- Normalize quantities, clarify ambiguous steps, infer timers.
- Output structured steps suitable for slide-based UI.
- KV cache for normalized recipes by hash.

## Non-Goals (for now)
- Grocery delivery, social features, or community uploads.
- Full video capture or editing.
- Advanced nutrition tracking.

## MVP Scope
- iPhone-first Cooking Mode with voice navigation (iPad compatible).
- 10–20 curated recipes with normalized steps.
- Timer creation and auto-advance.
- Q&A for basic “how-to” questions.

## Future Ideas
- Personalized pacing by user history.
- Auto-parallelization of steps.
- Smart display integrations.
