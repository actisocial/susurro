# Susurro — dictado local para macOS
#
# El flujo de firma es deliberado: xcodebuild compila SIN firmar y después
# firmamos a mano con la identidad "Apple Development". Eso deja un
# designated requirement estable (identifier + leaf CN), así los permisos de
# TCC (Micrófono, Accesibilidad, Monitorización de entrada) sobreviven a cada
# rebuild en vez de pedirse de nuevo cada vez, que es lo que pasa con la firma
# ad-hoc.

APP_NAME    := Susurro
BUNDLE_ID   := com.acti.susurro
SCHEME      := $(APP_NAME)
CONFIG      ?= Release
DD          := build/dd
APP         := $(DD)/Build/Products/$(CONFIG)/$(APP_NAME).app
INSTALL_DIR := /Applications

# Primera identidad de firma de código disponible. Se puede sobreescribir:
#   make build SIGN_ID="Developer ID Application: ..."
SIGN_ID ?= $(shell security find-identity -v -p codesigning | sed -n '1s/.*"\(.*\)".*/\1/p')

.DEFAULT_GOAL := build

.PHONY: project
project: ## Regenera Susurro.xcodeproj desde project.yml
	@command -v xcodegen >/dev/null || { echo "falta xcodegen: brew install xcodegen"; exit 1; }
	@xcodegen generate --quiet
	@echo "✓ proyecto generado"

.PHONY: build
build: project ## Compila y firma la app
	@echo "→ compilando $(APP_NAME) ($(CONFIG))…"
	@mkdir -p $(DD)
	@set -o pipefail; xcodebuild \
		-project $(APP_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(DD) \
		-skipPackagePluginValidation \
		-skipMacroValidation \
		CODE_SIGNING_ALLOWED=NO \
		build 2>&1 | tee $(DD)/build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)" \
		|| { \
			echo "✗ la compilación falló:"; \
			grep -E "error:" $(DD)/build.log | sort -u | head -20; \
			exit 1; \
		}
	@# `set -o pipefail` es lo que hace que esto sea correcto: sin él, el código
	@# de salida del pipe sería el de `grep`, un build fallido pasaría como
	@# bueno, se firmaría un .app viejo y `make` diría «listo». Un build roto
	@# tiene que parar acá.
	@test -d "$(APP)" || { echo "✗ no se generó el .app"; exit 1; }
	@$(MAKE) --no-print-directory strings
	@$(MAKE) --no-print-directory sign
	@echo "✓ $(APP)"

.PHONY: strings
strings: ## Sincroniza el catálogo de cadenas y aplica el inglés
	@# Todo el trabajo está en el script: encuentra los .stringsdata que dejó el
	@# compilador, los sincroniza con `xcstringstool` y recién ahí pone el
	@# inglés. Ese orden es lo que evita escribir a mano claves con %@ y %lld.
	@python3 Tools/localize.py

.PHONY: sign
sign: ## Firma el bundle con hardened runtime + entitlements
	@test -n "$(SIGN_ID)" || { echo "✗ no hay identidad de firma"; exit 1; }
	@echo "→ firmando con: $(SIGN_ID)"
	@codesign --force --options runtime --timestamp=none \
		--entitlements Susurro/Susurro.entitlements \
		--sign "$(SIGN_ID)" "$(APP)"
	@codesign --verify --strict --verbose=1 "$(APP)" 2>&1 | tail -1

.PHONY: run
run: build ## Compila, mata la instancia previa y lanza
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@open "$(APP)"
	@echo "✓ corriendo (buscá el ícono en la barra de menús)"

.PHONY: install
install: build ## Copia la app a /Applications
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP)" "$(INSTALL_DIR)/"
	@echo "✓ instalada en $(INSTALL_DIR)/$(APP_NAME).app"

.PHONY: test
test: project ## Corre los tests unitarios
	@set -o pipefail; xcodebuild test \
		-project $(APP_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath $(DD) \
		-skipPackagePluginValidation \
		-skipMacroValidation \
		CODE_SIGNING_ALLOWED=NO 2>&1 | tee $(DD)/test.log \
		| grep -E "error:|Test .*(passed|failed)|recorded an issue|Suite .* (passed|failed)" || true
	@# Swift Testing no reporta por el canal de XCTest —ahí siempre dice
	@# "Executed 0 tests"— así que el veredicto se saca de sus propias líneas.
	@# `grep -c` ya imprime 0 cuando no hay coincidencias, pero sale con código 1.
	@# Un `|| echo 0` detrás agrega un segundo cero y rompe la comparación.
	@FAILED=$$(grep -c "recorded an issue" $(DD)/test.log 2>/dev/null; true); \
	PASSED=$$(grep -c "Test \".*\" passed" $(DD)/test.log 2>/dev/null; true); \
	echo ""; \
	if [ "$$FAILED" -gt 0 ]; then \
		echo "✗ $$FAILED fallo(s), $$PASSED pasaron"; exit 1; \
	else \
		echo "✓ $$PASSED tests pasaron"; \
	fi

.PHONY: stop
stop: ## Cierra la app
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null && echo "✓ cerrada" || echo "no estaba corriendo"

.PHONY: reset-permissions
reset-permissions: ## Revoca los permisos de TCC para volver a probar el onboarding
	@tccutil reset Microphone $(BUNDLE_ID) 2>/dev/null || true
	@tccutil reset Accessibility $(BUNDLE_ID) 2>/dev/null || true
	@tccutil reset ListenEvent $(BUNDLE_ID) 2>/dev/null || true
	@echo "✓ permisos reseteados para $(BUNDLE_ID)"

.PHONY: clean
clean: ## Borra artefactos de build
	@rm -rf build $(APP_NAME).xcodeproj
	@echo "✓ limpio"

.PHONY: models-dir
models-dir: ## Muestra dónde viven los modelos descargados y cuánto pesan
	@DIR="$$HOME/Library/Application Support/$(APP_NAME)/Models"; \
	echo "$$DIR"; \
	[ -d "$$DIR" ] && du -sh "$$DIR"/* 2>/dev/null || echo "(sin modelos todavía)"

.PHONY: help
help: ## Lista los targets
	@grep -E '^[a-z-]+:.*?## .+$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
