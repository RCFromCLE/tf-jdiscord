# author: Rudy Corradetti
############################################ terraform and provider blocks ############################################
terraform {
  required_version = ">=0.12"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~>4.0"
    }
  }
}
provider "azurerm" {
  features {}
  subscription_id = var.sub
}

############################################ data sources ############################################
data "azurerm_key_vault" "jdiscord_kv" {
  name                = "jdiscord-kv"
  resource_group_name = "jdiscord-kv-rg"
}

data "azurerm_key_vault_secret" "ssh_public_key" {
  name         = "ssh-public-key"
  key_vault_id = azurerm_key_vault.jdiscord_kv.id
}

locals {
  ssh_public_key = trimspace(data.azurerm_key_vault_secret.ssh_public_key.value)
}
data "azurerm_key_vault_secret" "ssh_private_key" {
  name         = "ssh-private-key"
  key_vault_id = data.azurerm_key_vault.jdiscord_kv.id
}

############################################ resource blocks ############################################
# create a resource group
resource "azurerm_resource_group" "rg1" {
  name     = var.rg
  location = var.rg_loc
}
# create virtual network
resource "azurerm_virtual_network" "vnet1" {
  name                = var.net
  address_space       = ["10.0.0.0/23"]
  location            = azurerm_resource_group.rg1.location
  resource_group_name = azurerm_resource_group.rg1.name
}
# create subnet
resource "azurerm_subnet" "subnet1" {
  name                 = var.subnet
  resource_group_name  = azurerm_resource_group.rg1.name
  virtual_network_name = azurerm_virtual_network.vnet1.name
  address_prefixes     = ["10.0.1.0/24"]
}
# create public ips
resource "azurerm_public_ip" "public_ip" {
  name                = var.pub_ip
  location            = azurerm_resource_group.rg1.location
  resource_group_name = azurerm_resource_group.rg1.name
  allocation_method   = var.pub_allocation_method
}
# create network security group and rule
resource "azurerm_network_security_group" "nsg" {
  name                = var.nsg
  location            = azurerm_resource_group.rg1.location
  resource_group_name = azurerm_resource_group.rg1.name

  security_rule {
    name                       = "ssh"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
# create network interface
resource "azurerm_network_interface" "nic" {
  name                = var.nic_name
  location            = azurerm_resource_group.rg1.location
  resource_group_name = azurerm_resource_group.rg1.name

  ip_configuration {
    name                          = var.nic_priv_ip_name
    subnet_id                     = azurerm_subnet.subnet1.id
    private_ip_address_allocation = var.priv_allocation_method
    public_ip_address_id          = azurerm_public_ip.public_ip.id
  }
}
# connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "nsg_nic_assoc" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}
# create a virtual machine run jdiscordbot service
resource "azurerm_linux_virtual_machine" "vm1" {
  name                            = "jdb-vm"
  location                        = azurerm_resource_group.rg1.location
  resource_group_name             = azurerm_resource_group.rg1.name
  network_interface_ids           = [azurerm_network_interface.nic.id]
  size                            = "Standard_B1ms"
  admin_username                  = var.vm_admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = local.ssh_public_key
  }

  os_disk {
    name                 = "os-disk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18_04-lts-gen2"
    version   = "latest"
  }
}
# Create a local file to store the config.txt file - DO NOT CHECK CONFIG.TXT INTO VERSION CONTROL.
# data "local_file" "config_txt" {
#   filename = "${path.module}/config.txt" # Ensure the path to config.txt is correct
# }
data "azurerm_public_ip" "vm_ip" {
  name                = azurerm_public_ip.public_ip.name
  resource_group_name = azurerm_resource_group.rg1.name
}
resource "azurerm_virtual_machine_extension" "run_jdiscordbot" {
  name                 = "run_jdiscordbot"
  virtual_machine_id   = azurerm_linux_virtual_machine.vm1.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  settings = jsonencode({
    "script": base64encode(<<-EOT
      #!/bin/bash
      ${var.remove_tfjdiscord_command}
      sudo add-apt-repository -y ppa:openjdk-r/ppa
      sudo apt-get update
      sudo apt-get install -y default-jdk
      sudo git clone ${var.repo_url} /home/${var.vm_admin_username}/tf-jdiscord
      sudo mkdir -p /home/${var.vm_admin_username}/tf-jdiscord/jdiscordmusicbot
      echo 'token = ${var.discord_bot_token}' | sudo tee /home/${var.vm_admin_username}/tf-jdiscord/jdiscordmusicbot/config.txt
      echo 'owner = ${var.discord_bot_owner}' | sudo tee -a /home/${var.vm_admin_username}/tf-jdiscord/jdiscordmusicbot/config.txt
      echo 'prefix = ${var.discord_bot_prefix}' | sudo tee -a /home/${var.vm_admin_username}/tf-jdiscord/jdiscordmusicbot/config.txt
      sudo chown ${var.vm_admin_username}:${var.vm_admin_username} /home/${var.vm_admin_username}/tf-jdiscord/jdiscordmusicbot/config.txt
      sudo chmod 644 /home/${var.vm_admin_username}/tf-jdiscord/jdiscordmusicbot/config.txt
      sudo chown -R ${var.vm_admin_username}:${var.vm_admin_username} /home/${var.vm_admin_username}/tf-jdiscord
      echo '[Unit]' | sudo tee /etc/systemd/system/jdiscordbot.service
      echo 'Description=JDiscordBot Service' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      echo 'After=network.target' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      echo '[Service]' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      echo 'Type=simple' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      echo 'User=${var.vm_admin_username}' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      echo 'WorkingDirectory=/home/${var.vm_admin_username}/tf-jdiscord/jdiscordmusicbot' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      echo 'ExecStart=/usr/bin/java -jar /home/${var.vm_admin_username}/tf-jdiscord/jdiscordmusicbot/${var.jar_path}' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      echo 'Restart=on-failure' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      echo '[Install]' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      echo 'WantedBy=multi-user.target' | sudo tee -a /etc/systemd/system/jdiscordbot.service
      sudo systemctl enable jdiscordbot.service
      sudo systemctl start jdiscordbot.service
    EOT
    )
  })

  depends_on = [azurerm_linux_virtual_machine.vm1]
}
# Create a random string for the storage account name
resource "random_string" "sa_suffix" {
  length  = 5 # Adjusted length for the suffix
  special = false
  upper   = false
  numeric = true
  lower   = true # Ensure lowercase is explicitly stated, though it's the default
}
# storage account for function app
resource "azurerm_storage_account" "functionapp_sa" {
  name                     = "jdiscordstorage${random_string.sa_suffix.result}"
  resource_group_name      = azurerm_resource_group.rg1.name
  location                 = azurerm_resource_group.rg1.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
resource "azurerm_storage_container" "functionapp_container" {
  name                  = "jdiscord-code"
  storage_account_name  = azurerm_storage_account.functionapp_sa.name
  container_access_type = "private"
}
# Linux app service plan.
resource "azurerm_service_plan" "functionapp_plan" {
  name                = "jdiscord-app-service-plan"
  location            = azurerm_resource_group.rg1.location
  resource_group_name = azurerm_resource_group.rg1.name
  os_type             = "Linux"
  sku_name            = "Y1" # "Y1" is the SKU for the Consumption plan.
}
# Application insights for monitoring.
resource "azurerm_application_insights" "app_insights" {
  name                = "jdiscord-appinsights"
  location            = azurerm_resource_group.rg1.location
  resource_group_name = azurerm_resource_group.rg1.name
  application_type    = "web"
}
# Linux function app
resource "azurerm_linux_function_app" "jdiscord_function" {
  name                       = "jdiscord-function"
  location                   = azurerm_resource_group.rg1.location
  resource_group_name        = azurerm_resource_group.rg1.name
  service_plan_id            = azurerm_service_plan.functionapp_plan.id
  storage_account_name       = azurerm_storage_account.functionapp_sa.name
  storage_account_access_key = azurerm_storage_account.functionapp_sa.primary_access_key
  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"       = "node"                 # This is the runtime for the function app, do not change this unless you know what you're doing.
    "GENERAL_CHANNEL_ID"             = var.general_channel_id # this is the channel id for the general channel where the music bot will send status updates
    "AFK_CHANNEL_ID"                 = var.afk_channel_id     # this is the channel id for the afk channel
    "MUSIC_CHANNEL_ID"               = var.music_channel_id   # this is the channel id for the music bot channel
    "DISCORD_BOT_TOKEN"              = var.discord_bot_token  # this is the bot token
    "AZURE_TENANT_ID"                = var.azure_tenant_id
    "AZURE_CLIENT_ID"                = var.azure_client_id # this is the client id of the service principal - grant sp access to the resource group or subscription to reboot the vm
    "AZURE_CLIENT_SECRET"            = var.azure_client_secret
    "SUBSCRIPTION_ID"                = var.sub
    "RESOURCE_GROUP_NAME"            = azurerm_resource_group.rg1.name
    "VM_NAME"                        = var.vm_name # Assuming you have this defined elsewhere or passed as a variable.
    "APPINSIGHTS_INSTRUMENTATIONKEY" = azurerm_application_insights.app_insights.instrumentation_key
  }
  site_config {
    application_stack {
      node_version = "18" # This is the version of node that the function app will use. Do not change this unless you know what you're doing.
    }
  }
  lifecycle {
    ignore_changes = [
      app_settings["APPINSIGHTS_INSTRUMENTATIONKEY"],
      site_config[0].application_insights_key,
    ]
  }
}