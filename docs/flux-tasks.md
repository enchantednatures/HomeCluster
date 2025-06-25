# Flux Task Reference

Your Flux tasks have been updated with current best practices and new functionality.

## Available Tasks

### 🚀 **Bootstrap & Setup**
```bash
task flux:bootstrap              # Full Flux bootstrap (first-time setup)
task flux:github-deploy-key      # Apply GitHub deploy key for private repos
task flux:validate               # Validate Flux configuration files
```

### 🔄 **Daily Operations**
```bash
task flux:reconcile              # Full reconcile of all cluster phases
task flux:reconcile-fast         # Quick reconcile (source + foundation only)
task flux:status                 # Show status of all cluster kustomizations
task flux:apply path=<app-path>  # Apply specific app kustomization
```

### 🔍 **Debugging & Monitoring**
```bash
task flux:logs                   # Show kustomize-controller logs
task flux:logs controller=source-controller  # Show specific controller logs
task flux:logs lines=100         # Show more log lines
```

### 🌍 **Multi-Tenancy Support**
```bash
task flux:switch-environment env=production   # Switch to production config
task flux:switch-environment env=local        # Switch to local dev config
```

## What Changed

### ✅ **Updated for Current Cluster**
- **Reconcile task**: Now targets current kustomization names (`cluster-0-foundation`, etc.)
- **Bootstrap task**: Uses correct paths and includes user settings
- **Validation**: Checks both Flux prerequisites and cluster config

### 🆕 **New Tasks Added**
- **`flux:status`**: Quick overview of all cluster kustomizations
- **`flux:reconcile-fast`**: Fast reconcile for development workflows
- **`flux:logs`**: Easy access to Flux controller logs
- **`flux:validate`**: Pre-flight checks for configuration
- **`flux:switch-environment`**: Multi-tenancy environment switching

### 🔧 **Enhanced Features**
- **Better error handling**: Clear preconditions and validation
- **Progress feedback**: Visual indicators for long-running operations
- **Flexible options**: Configurable parameters for logs, controllers, etc.

## Common Usage Patterns

### **After Making Changes**
```bash
# Quick update during development
task flux:reconcile-fast

# Full reconcile after major changes
task flux:reconcile

# Check status
task flux:status
```

### **Troubleshooting**
```bash
# Check what's failing
task flux:status

# View controller logs
task flux:logs

# Validate configuration
task flux:validate
```

### **Multi-Environment Workflow**
```bash
# Switch to local for testing
task flux:switch-environment env=local

# Switch back to production
task flux:switch-environment env=production
```

Your Flux tasks are now modern, comprehensive, and aligned with your current cluster setup!