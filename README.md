# 🔔 RepReminders

Application de rappels répétitifs pour iOS, iPadOS, macOS et watchOS.
Envoie des notifications toutes les X minutes jusqu'à ce que tu valides.

---

## Prérequis

- macOS 14 Sonoma ou plus
- Xcode 15 ou plus
- Homebrew (https://brew.sh)

---

## Installation en 3 étapes

### Étape 1 — Décompresser et lancer le setup

```bash
cd ~/Downloads/RepReminders
chmod +x setup.sh
./setup.sh
```

Le script installe XcodeGen (via Homebrew), génère le projet `.xcodeproj` et ouvre Xcode.

### Étape 2 — Configurer la signature dans Xcode

1. Sélectionne la target **RepReminders**
2. Onglet **Signing & Capabilities**
3. Choisis ton **Team** (compte Apple Developer)
4. Répète pour la target **RepRemindersWatch**

### Étape 3 — Lancer l'app

- **iPhone/iPad** : sélectionne ton appareil → ▶
- **macOS** : sélectionne "My Mac (Designed for iPad)" → ▶
- **Apple Watch** : sélectionne ta montre → ▶
- Autorise les **notifications** au premier lancement

---

## Utilisation

### Depuis l'app

1. Appuie sur **+** pour créer un rappel
2. Remplis titre, date/heure, intervalle, nombre de répétitions
3. Balaye vers la droite → **Validé !** pour arrêter les notifications

### Depuis l'app Raccourcis Apple

Deux actions sont disponibles sous "RepReminders" :

**"Créer un rappel répétitif"**
- Titre, Date de début, Intervalle (min), Nombre max de répétitions

**"Valider la présence"**
- Titre du rappel (doit correspondre exactement)

### Exemple de Raccourci pour l'émargement

```
[Obtenir les événements du calendrier]  →  Aujourd'hui
[Choisir dans la liste]                 →  Sélection du cours
[Obtenir les détails]                   →  Date de début
[Créer un rappel répétitif]
   Titre       = "Valider ma présence – [Nom du cours]"
   Début       = Date de début du cours
   Intervalle  = 5
   Répétitions = 20  (couvre 100 minutes)
```

Second raccourci (widget ou bouton d'action) :
```
[Valider la présence]
   Titre = "Valider ma présence"
```

---

## Fonctionnement

- Notifications planifiées **localement** à la création du rappel
- Chaque notification inclut un bouton **"✓ Valider ma présence"**
- Appuyer sur ce bouton annule toutes les notifications suivantes

## Limitations

- iOS limite à ~64 notifications planifiées par app
- watchOS a son propre store de données (pas de sync automatique avec iPhone sans CloudKit)

---

## Structure du projet

```
Shared/     ← Reminder.swift, NotificationManager.swift, AppIntents.swift
iOS/        ← RepRemindersApp.swift, ContentView.swift, AddReminderView.swift
watchOS/    ← RepRemindersWatchApp.swift, WatchContentView.swift
```
