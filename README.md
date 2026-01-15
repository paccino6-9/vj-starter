# VJ Starter (macOS + Metal) — Core + Plugin SDK

Ceci est un **kit de départ open source** pour créer un logiciel type VJ / video sampler sur **macOS uniquement**, avec rendu **Metal**,
et un système de **plugins** orienté **générateurs / effets / transitions**.

L’objectif est de rendre le développement de plugins *très simple* :
- un plugin déclare ses **paramètres**
- et implémente un **render()** qui reçoit des textures Metal
- le core (à écrire/compléter) s’occupe du reste (timing, décodage vidéo, UI, MIDI/OSC, cache…)

> ⚠️ Ce repo est un **starter kit** : le “Core” est volontairement minimal (stubs + contrat d’API).
> Les exemples de plugins compilent et montrent le pattern.

---

## Arborescence

- `SDK/`
  - `include/` : API C stable + wrapper C++
  - `templates/` : squelette de plugin
- `Plugins/Examples/`
  - `TranceGlow` : effet type trance (glow + rotation + posterize optionnel)
  - `MandalaGen` : générateur mandala (shader procedural)
- `Tools/`
  - scripts de build + helpers
- `Core/`
  - stubs de host (à remplacer par ton moteur + UI)

---

## Prérequis

- macOS + Xcode Command Line Tools
- clang++
- Frameworks: Metal, Foundation

Installe les CLT :
```bash
xcode-select --install
```

---

## Compiler les exemples (le plus simple)

Depuis la racine du projet :

```bash
cd Tools
./build_examples.sh
```

Les `.dylib` sont déposées dans :
`Build/Plugins/`

---

## Chargement des plugins (côté Core)

Le core doit :
1. `dlopen()` la dylib
2. récupérer `vj_plugin_get_descriptor()` (symbol)
3. appeler `create()` puis `render()` dans le thread rendu

Les fonctions et structures sont dans :
`SDK/include/vj_plugin_api.h`

---

## Licence

MIT — fais-toi plaisir.
