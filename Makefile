.PHONY: backup help install deploy package packages clean-packages

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

# Package: DB2 Backup Standalone
package-db2-backup:
	@echo "Creating db2-backup.tar.gz..."
	@tar -czf db2-backup.tar.gz backup-db2.sh etc/backup-config.yaml DB2_BACKUP_README.md README.md
	@echo "✓ Created db2-backup.tar.gz"
	@ls -lh db2-backup.tar.gz

# Package: DB2 Backup Full Deployment
package-db2-deploy:
	@echo "Creating db2-backup-deploy.tar.gz..."
	@tar -czf db2-backup-deploy.tar.gz deploy.sh backup-db2.sh etc/backup-config.yaml Makefile README.md LICENSE DB2_DEPLOY_README.md
	@echo "✓ Created db2-backup-deploy.tar.gz"
	@ls -lh db2-backup-deploy.tar.gz

# Package: NFS Backup Deployment
package-nfs-deploy:
	@echo "Creating nfs-backup-deploy.tar.gz..."
	@tar -czf nfs-backup-deploy.tar.gz deploy_nfs_backup.sh etc/nfs-deploy-config.yaml NFS_DEPLOY_README.md
	@echo "✓ Created nfs-backup-deploy.tar.gz"
	@ls -lh nfs-backup-deploy.tar.gz

# Package: All tar files
packages: package-db2-backup package-db2-deploy package-nfs-deploy
	@echo ""
	@echo "=========================================="
	@echo "All packages created successfully!"
	@echo "=========================================="
	@ls -lh *.tar.gz

# Clean: Remove all tar files
clean-packages:
	@echo "Removing tar files..."
	@rm -f db2-backup.tar.gz db2-backup-deploy.tar.gz nfs-backup-deploy.tar.gz
	@echo "✓ Cleaned up tar files"

# Show help
help:
	@echo "DB2 Backup Script"
	@echo ""
	@echo "Usage:"
	@echo "  make deploy            - Deploy to system (requires root, uses deploy.sh)"
	@echo "  make install           - Install script locally (create directories)"
	@echo "  make backup           - Run backup"
	@echo "  ./backup-db2.sh        - Run backup directly"
	@echo ""
	@echo "Packaging:"
	@echo "  make packages         - Create all tar packages"
	@echo "  make package-db2-backup   - Create standalone DB2 backup package"
	@echo "  make package-db2-deploy    - Create full DB2 deployment package"
	@echo "  make package-nfs-deploy    - Create NFS deployment package"
	@echo "  make clean-packages  - Remove all tar files"
	@echo ""
	@echo "Deployment:"
	@echo "  sudo ./deploy.sh - Deploy system-wide (recommended)"
	@echo ""
	@echo "Configuration:"
	@echo "  Edit etc/backup-config.yaml to configure backup settings"

