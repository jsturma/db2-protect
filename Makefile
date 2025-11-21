.PHONY: backup help install

# Default backup
backup:
	@bash backup-db2.sh

# Install script (make executable)
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
	@echo "  make install    - Install script and create directories"
	@echo "  make backup     - Run backup"
	@echo "  ./backup-db2.sh - Run backup directly"
	@echo ""
	@echo "Configuration:"
	@echo "  Edit etc/backup-config.yaml to configure backup settings"

