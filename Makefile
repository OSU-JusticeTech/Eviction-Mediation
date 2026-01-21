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

# Import environment-specific overrides if available
-include env.mk

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

credentials:
	$(COMPOSE_CMD) exec $(WEB_SERVICE) bin/rails credentials:edit

# Import makefile target overrides if available
-include env-targets.mk