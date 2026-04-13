#!/bin/bash
# ──────────────────────────────────────────
#  RepeatRemind – Setup Script
#  Installe XcodeGen si nécessaire et génère
#  le projet Xcode, puis l'ouvre.
# ──────────────────────────────────────────

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo "🔔  RepeatRemind – Setup"
echo "────────────────────────"
echo ""

# 1. Vérifier que Homebrew est installé
if ! command -v brew &> /dev/null; then
    echo -e "${RED}❌  Homebrew n'est pas installé.${NC}"
    echo "    Installe-le d'abord via : https://brew.sh"
    exit 1
fi
echo -e "${GREEN}✓${NC}  Homebrew trouvé"

# 2. Installer XcodeGen si absent
if ! command -v xcodegen &> /dev/null; then
    echo -e "${YELLOW}📦  Installation de XcodeGen...${NC}"
    brew install xcodegen
fi
echo -e "${GREEN}✓${NC}  XcodeGen prêt ($(xcodegen --version))"

# 3. Se placer dans le dossier du script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 4. Générer le projet Xcode
echo ""
echo "⚙️   Génération du projet Xcode..."
xcodegen generate

# 5. Ouvrir Xcode
echo ""
echo -e "${GREEN}✅  Projet généré avec succès !${NC}"
echo ""
echo "📋  Prochaines étapes :"
echo "    1. Sélectionne ton équipe de développement dans :"
echo "       Xcode → RepeatRemind (target) → Signing & Capabilities"
echo "    2. Lance l'app sur ton iPhone ou simulateur"
echo "    3. Autorise les notifications au premier lancement"
echo ""
open RepReminders.xcodeproj
