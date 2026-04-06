# Default configuration variables - override defaults in env.mk
export COMPOSE_FILE := docker-compose.yml
export DB_PASSWORD := StrongPassword1
export DB_USER := sa
export DB_HOST := localhost
export DB_INIT_FILE := DBInitTest.sql
export DB_SOURCE_NAME := EVICTION_TEST
export DB_TARGET_NAME := EVICTION_DEVELOPMENT
export COMPOSE_CMD := docker compose
export WEB_SERVICE := web
export DB_SERVICE := db
export WEB_PORT := 3000
export DB_PORT := 1433
export RAILS_ENV := development
export DB_ADAPTER := sqlserver
export RAILS_MASTER_KEY := 
export RAILS_LOG_TO_STDOUT := true
export RAILS_SERVE_STATIC_FILES := true
export APP_URL := localhost:$(WEB_PORT)
export APP_PROTOCOL := http
export EXPORT_FILE := db_export.bak

# Import environment-specific overrides if available
-include env.mk

# Ensures make ignores file/directory name collisions for these targets
.PHONY: test test-all test-system-headed

dev-setup: down-clean
	@test -f config/database.yml || cp config/database.yml.docker config/database.yml
	$(COMPOSE_CMD) build
	$(COMPOSE_CMD) up -d --wait
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails db:create
	sed 's/$(DB_SOURCE_NAME)/$(DB_TARGET_NAME)/g' $(DB_INIT_FILE) > setup_temp.sql
	$(COMPOSE_CMD) cp setup_temp.sql $(DB_SERVICE):/tmp/setup.sql
	$(COMPOSE_CMD) exec $(DB_SERVICE) /opt/mssql-tools/bin/sqlcmd -S $(DB_HOST) -U $(DB_USER) -P '$(DB_PASSWORD)' -i /tmp/setup.sql
	rm setup_temp.sql
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails db:schema:dump
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails db:migrate
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails db:seed
	@echo "🎉 Setup complete! Your app is running at http://localhost:3000"

up:
	$(COMPOSE_CMD) up -d

down:
	$(COMPOSE_CMD) down

down-clean:
	$(COMPOSE_CMD) down -v

logs:
	$(COMPOSE_CMD) logs -f

build:
	$(COMPOSE_CMD) build

test:
	$(COMPOSE_CMD) up -d db
	$(COMPOSE_CMD) run --rm -e RAILS_ENV=test $(WEB_SERVICE) bin/rails db:create 
	$(COMPOSE_CMD) run --rm -e RAILS_ENV=test $(WEB_SERVICE) bin/rails db:prepare
	$(COMPOSE_CMD) run --rm -e RAILS_ENV=test $(WEB_SERVICE) sh -lc 'rm -f coverage/.resultset.json coverage/.last_run.json'
	@if [ "$(TEST)" = "test:all" ]; then \
		$(COMPOSE_CMD) run --rm -e RAILS_ENV=test $(WEB_SERVICE) bin/rails test; \
		$(COMPOSE_CMD) run --rm -e RAILS_ENV=test $(WEB_SERVICE) bin/rails test test/system; \
	else \
		$(COMPOSE_CMD) run --rm -e RAILS_ENV=test $(WEB_SERVICE) bin/rails test $(TEST); \
	fi

#Test unit tests and system tests
test-all:
	$(MAKE) test TEST=test:all

#Test with a headed version of Chrome to witness tests live on port 7900
test-system-headed:
	$(COMPOSE_CMD) up -d db chrome web
	$(COMPOSE_CMD) exec -e RAILS_ENV=test $(WEB_SERVICE) bin/rails db:create
	$(COMPOSE_CMD) exec -e RAILS_ENV=test $(WEB_SERVICE) bin/rails db:prepare
	@echo "Open http://localhost:7900/?autoconnect=1&resize=scale to watch browser actions"
	$(COMPOSE_CMD) exec -e RAILS_ENV=test -e SYSTEM_TEST_HEADLESS=false $(WEB_SERVICE) bin/rails test $(or $(TEST),test/system)

web-shell:
	$(COMPOSE_CMD) exec $(WEB_SERVICE) /bin/bash

db-shell:
	$(COMPOSE_CMD) exec $(DB_SERVICE) /opt/mssql-tools/bin/sqlcmd -S $(DB_HOST) -U $(DB_USER) -P '$(DB_PASSWORD)'

db-setup:
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails db:create db:migrate

db-seed:
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails db:seed
	@echo "📋 Sample accounts created"

db-reset:
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails db:drop db:create db:migrate

db-init:
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails db:create
	$(COMPOSE_CMD) cp $(DB_INIT_FILE) $(DB_SERVICE):/tmp/init.sql
	$(COMPOSE_CMD) exec $(DB_SERVICE) sed 's/$(DB_SOURCE_NAME)/$(DB_TARGET_NAME)/g' /tmp/init.sql > /tmp/setup.sql
	$(COMPOSE_CMD) exec $(DB_SERVICE) /opt/mssql-tools/bin/sqlcmd -S $(DB_HOST) -U $(DB_USER) -P '$(DB_PASSWORD)' -i /tmp/setup.sql
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails db:migrate

export-db:
	$(COMPOSE_CMD) exec $(DB_SERVICE) /opt/mssql-tools/bin/sqlcmd -S $(DB_HOST) -U $(DB_USER) -P '$(DB_PASSWORD)' -Q "BACKUP DATABASE [$(DB_TARGET_NAME)] TO DISK = N'/tmp/export.bak' WITH FORMAT, INIT"
	$(COMPOSE_CMD) cp $(DB_SERVICE):/tmp/export.bak $(EXPORT_FILE)
	@echo "Database exported to $(EXPORT_FILE)"

import-db:
	$(COMPOSE_CMD) cp $(or $(FILE),$(EXPORT_FILE)) $(DB_SERVICE):/tmp/import.bak
	$(COMPOSE_CMD) exec -u root $(DB_SERVICE) chmod 644 /tmp/import.bak
	$(COMPOSE_CMD) exec $(DB_SERVICE) /opt/mssql-tools/bin/sqlcmd -S $(DB_HOST) -U $(DB_USER) -P '$(DB_PASSWORD)' -Q "ALTER DATABASE [$(DB_TARGET_NAME)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; RESTORE DATABASE [$(DB_TARGET_NAME)] FROM DISK = N'/tmp/import.bak' WITH REPLACE; ALTER DATABASE [$(DB_TARGET_NAME)] SET MULTI_USER;"
	$(COMPOSE_CMD) restart $(WEB_SERVICE)
	@echo "Database imported from $(or $(FILE),$(EXPORT_FILE))"

credentials:
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails credentials:edit

# Import makefile target overrides if available
-include env-targets.mk