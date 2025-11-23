.PHONY: backup help install deploy

# Default backup
backup:
	@bash backup-db2.sh

# Deploy to system (requires root)
deploy:
	@echo "Deploying DB2 Protect..."
	@sudo ./deploy.sh

# Install script (make executable) - local development
install:
	@chmod +x backup-db2.sh
	@mkdir -p logs etc
	@if [ ! -f etc/backup-config.yaml ]; then \
		echo "Please create etc/backup-config.yaml from etc/backup-config.yaml.example"; \
	fi

# Show help
help:
	@echo "DB2 Backup Script"
	@echo ""
	@echo "Usage:"
	@echo "  make deploy     - Deploy to system (requires root, uses deploy.sh)"
	@echo "  make install    - Install script locally (create directories)"
	@echo "  make backup     - Run backup"
	@echo "  ./backup-db2.sh - Run backup directly"
	@echo ""
	@echo "Deployment:"
	@echo "  sudo ./deploy.sh - Deploy system-wide (recommended)"
	@echo ""
	@echo "Configuration:"
	@echo "  Edit etc/backup-config.yaml to configure backup settings"

