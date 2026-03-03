#!/bin/bash
#
# wordpress-deploy.sh - staging to production push for WordPress
#
# Rsyncs files, migrates the database, preserves WooCommerce orders
# (legacy CSV or HPOS table export), optionally handles Gravity Forms
# entries, does URL search-replace, and clears caches.
#
# Usage: ./wordpress-deploy.sh sitename.com
# Config: config/wordpress/.<site_name> (dotfile, supports CI env var overrides)
#
# Expects SSH key access, a deploy user with passwordless sudo,
# WP-CLI, rsync, mysqldump/mysql, and mailx on the relevant hosts.
#
# Shift8 Web, 2026
#

if [ -z "$1" ];
then
        echo "WP PUSH"
        echo "-------"
        echo ""
        echo "Usage : ./wordpress-deploy.sh sitename.com"
        echo ""
        exit 0
fi

currentdate=`date "+%Y-%m-%d-%s"`
scriptpath="/usr/local/bin/wordpress-deploy"

# Derive config-safe name from domain (lowercase, underscores, max 15 chars)
site_name=`echo "$1" |  awk -F "." '{printf "%s\n" ,$1}' | sed 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/' | sed 's/-/_/g' | awk -F. '{str="";if ( length($1) > 16 ) str="";print substr($1,0,15)str""$2}'`

source ${scriptpath}/config/wordpress/.${site_name}

alert_notification() {
    echo "Push script failure : $2" | mail -s "$site_name : Push script Failure" $1
}

# Exit with alert if last command failed
sanity_check() {
    if [ $1 -ne 0 ]
    then
        echo "$2"
        alert_notification $alert_email "$2"
        exit 1
    fi
}

urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="$c" ;;
            * ) printf -v o '%%%02X' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# Pre-flight check on staging
echo "Running pre-flight WordPress check on staging .."
check_staging_health=`ssh -l $staging_user $staging_host "sudo ${wp_cli_staging} --path=\"${source_dir}\" eval 'echo \"OK\";'" 2>&1`
sanity_check $? "Pre-flight check failed on staging : $check_staging_health"

# Maintenance mode on
echo "Enabling maintenance mode.."
ssh -l $destination_user $destination_host \
    "cd $destination_dir;\
    sudo mv maintenance_off.html maintenance_on.html"

# Rsync files staging -> production
echo "Transferring files from staging to production.."
ssh -l $staging_user $staging_host \
    "cd $source_dir;\
    sudo /usr/bin/rsync --rsync-path='sudo /usr/bin/rsync' -rlptDu --exclude='wp-config.php' --exclude='.htaccess' --exclude='gravity_forms' --exclude='maintenance_on.html' --exclude='maintenance_off.html' --delete ${source_dir}/ ${destination_user}@${destination_host}:${destination_dir}"


# WooCommerce order-safe push
if [ "$woocommerce_enable" == "true" ]
then

    echo "Backing up production database .."
    check_prod_backup=`ssh -l $destination_user $destination_host sudo bash -c "'/usr/bin/mysqldump -u $prod_db_user --password=\"$prod_db_password\" -h $prod_db_host $prod_db_name | gzip >  ${prod_db_backup_dir}/${prod_db_name}_${currentdate}.sql.gz'"`
    sanity_check $? "Error with production database backup : $check_prod_backup"

    if [ "$woocommerce_hpos" == "true" ]
    then
        # Export HPOS core tables only (not legacy line items, avoids PK conflicts)
		echo "Exporting HPOS core tables from production .."
        echo "HPOS export stored at: ${prod_db_backup_dir}/orders_export_hpos_${currentdate}.sql.gz"
		check_export_hpos_tables=`ssh -l $destination_user $destination_host sudo bash -c "'/usr/bin/mysqldump -u $prod_db_user --password=\"$prod_db_password\" -h $prod_db_host \
		$prod_db_name \
		wp_wc_orders \
		wp_wc_orders_meta \
		wp_wc_order_addresses \
		wp_wc_order_operational_data \
		wp_wc_order_stats \
		wp_wc_order_product_lookup \
		wp_wc_order_tax_lookup \
		wp_wc_customer_lookup | gzip > ${prod_db_backup_dir}/orders_export_hpos_${currentdate}.sql.gz'"`

		sanity_check $? "Error with HPOS order table export on production : $check_export_hpos_tables"

        # Export order protection data (line items + metadata)
        echo "Exporting order protection data for 80000+ orders.."
        check_protection_export=`ssh -l $destination_user $destination_host sudo bash -c "'${wp_cli_prod} --path=\"${destination_dir}\" shift8wcpush export_protection --backup-dir=\"${prod_db_backup_dir}\"'"`
        sanity_check $? "Error with order protection export on production : $check_protection_export"
    else 
        echo "Exporting all orders from production .."
        check_export_orders=`ssh -l $destination_user $destination_host sudo bash -c "'${wp_cli_prod} --path=\"${destination_dir}\" shift8wcpush export > ${prod_db_backup_dir}/orders_export_${currentdate}.csv'"`
        sanity_check $? "Error with order export on production : $check_export_orders"
    fi

    # Gravity Forms: save entries
    if [ "$gform_entries" == "true" ]
    then
        gform_ids=`ssh -l $destination_user $destination_host sudo bash -c "'${wp_cli_prod} --path=\"${destination_dir}\" gf form form_list --active --sort_column=id --format=ids | sed \"s/\s\+/\n/g\"'"`

        echo "Clearing out all entries for gravity forms on staging .."
        check_gravity_clear=`ssh -l $staging_user $staging_host sudo bash -c "'${wp_cli_staging} --path=\"${source_dir}\" db query \"truncate wp_gf_entry;truncate wp_gf_entry_meta;\"'"`
        sanity_check $? "Error with clearing out gravity form entries on staging : $check_gravity_clear"

        for obj0 in $(echo $gform_ids)
        do
            echo "Exporting form list id : $obj0"
            ssh -l $destination_user $destination_host sudo bash -c "'${wp_cli_prod} --path=\"${destination_dir}\" gf entry export $obj0 --dir=${prod_db_backup_dir} form_entries_${currentdate}_${obj0}.json --format=json'"
        done
    fi

    if [ "$woocommerce_hpos" == "false" ]
    then
        # Delete all orders from staging
        order_count_check=`ssh -l $staging_user $staging_host sudo bash -c "'${wp_cli_staging} --path=\"${source_dir}\" post list --post_type='shop_order' --format=ids | sed \"s/\s\+/\n/g\" | wc -l'"`
        if [ $order_count_check -ne 0 ] 
        then
            echo "Cleaning orders from staging .."
            check_staging_order_clear=`ssh -l $staging_user $staging_host sudo bash -c "'${wp_cli_staging} --path=\"${source_dir}\" post delete \\$(${wp_cli_staging} --path=\"${source_dir}\" post list --post_type=\"shop_order\" --format=ids) --force'"`
            sanity_check $? "Error with clearing out orders from staging : $check_staging_order_clear"
        fi
		order_refunds_count_check=`ssh -l $staging_user $staging_host sudo bash -c "'${wp_cli_staging} --path=\"${source_dir}\" post list --post_type='shop_order_refund' --format=ids | sed \"s/\s\+/\n/g\" | wc -l'"`
	    if [ $order_refunds_count_check -ne 0 ]
	    then
	        echo "Cleaning order refunds from staging .."
	        check_staging_order_refund_clear=`ssh -l $staging_user $staging_host sudo bash -c "'${wp_cli_staging} --path=\"${source_dir}\" post delete \\$(${wp_cli_staging} --path=\"${source_dir}\" post list --post_type=\"shop_order_refund\" --format=ids) --force'"`
	        sanity_check $? "Error with clearing out orders from staging : $check_staging_order_refund_clear"
	    fi
    fi

	# Dump staging DB, excluding HPOS tables (preserved from production)
	echo "Dumping staging database to temp file (excluding HPOS tables).."
	check_staging_temp=`ssh -l $staging_user $staging_host sudo bash -c "'/usr/bin/mysqldump -u $staging_db_user --password=\"$staging_db_password\" -h $staging_db_host \
	$staging_db_name \
	--ignore-table=${staging_db_name}.wp_wc_orders \
	--ignore-table=${staging_db_name}.wp_wc_orders_meta \
	--ignore-table=${staging_db_name}.wp_wc_order_addresses \
	--ignore-table=${staging_db_name}.wp_wc_order_operational_data \
	--ignore-table=${staging_db_name}.wp_wc_order_items \
	--ignore-table=${staging_db_name}.wp_wc_order_itemmeta \
	--ignore-table=${staging_db_name}.wp_wc_order_stats \
	--ignore-table=${staging_db_name}.wp_wc_order_product_lookup \
	--ignore-table=${staging_db_name}.wp_wc_order_tax_lookup \
	--ignore-table=${staging_db_name}.wp_wc_customer_lookup'" > ${scriptpath}/sqltmp/sqltmp.sql`
	sanity_check $? "Error with dumping staging database to temp file : $check_staging_temp"


    # Transfer Database to production
    echo "Transferring staging database to production.."
    check_prod_db=`cat ${scriptpath}/sqltmp/sqltmp.sql | ssh -l $destination_user $destination_host sudo bash -c "'/usr/bin/mysql -u $prod_db_user --password=\"$prod_db_password\" -h $prod_db_host $prod_db_name'"`
    sanity_check $? "Error with production database transfer : $check_prod_db"

    # Gravity Forms: restore entries
    if [ "$gform_entries" == "true" ]
    then
        for obj0 in $(echo $gform_ids)
        do
            echo "Importing form list id : $obj0"
            ssh -l $destination_user $destination_host sudo bash -c "'${wp_cli_prod} --path=\"${destination_dir}\" gf entry import $obj0 ${prod_db_backup_dir}/form_entries_${currentdate}_${obj0}.json'"
        done
    fi

    if [ "$woocommerce_hpos" == "true" ]
    then
	    echo "Importing HPOS tables back to production .."
	    check_import_hpos_tables=`ssh -l $destination_user $destination_host sudo bash -c "'gunzip < ${prod_db_backup_dir}/orders_export_hpos_${currentdate}.sql.gz | /usr/bin/mysql -u $prod_db_user --password=\"$prod_db_password\" -h $prod_db_host $prod_db_name'"`
	    sanity_check $? "Error with restoring HPOS order tables on production : $check_import_hpos_tables"

        # Import order protection data for 80000+ orders only
        echo "Restoring order protection data for 80000+ orders.."
        restore_script=`ssh -l $destination_user $destination_host sudo bash -c "'find ${prod_db_backup_dir} -name \"order_protection_restore_*.php\" -type f -printf \"%T@ %p\n\" | sort -n | tail -1 | cut -d\" \" -f2-'"`
        
        if [ ! -z "$restore_script" ]; then
            check_protection_import=`ssh -l $destination_user $destination_host sudo bash -c "'${wp_cli_prod} --path=\"${destination_dir}\" shift8wcpush import_protection --restore-script=\"${restore_script}\"'"`
            sanity_check $? "Error with order protection import on production : $check_protection_import"
        else
            echo "Warning: No order protection restore script found"
        fi

        # Check for orphaned orders
        ssh -l $destination_user $destination_host sudo bash -c "'${wp_cli_prod} --path=\"${destination_dir}\" shift8wcpush check_orphans'"
	else
	    echo "Importing all orders back to production .."
	    check_import_orders=`ssh -l $destination_user $destination_host sudo bash -c "'${wp_cli_prod} --path=\"${destination_dir}\" shift8wcpush import --import-file=${prod_db_backup_dir}/orders_export_${currentdate}.csv'"`
	    sanity_check $? "Error with order import on production : $check_import_orders"
	fi

    # Sleep for 30 seconds
    sleep 30

    echo "Running Wordpress cron on production .."
    check_wordpress_cron=`ssh -l $destination_user $destination_host sudo bash -c "'${php} ${destination_dir}/wp-cron.php'"`
    sanity_check $? "Error with running Wordpress cron on production : $check_wordpress_cron"

    echo "Running Wordpress action scheduler on production .."
    check_wordpress_action_scheduler=`ssh -l $destination_user $destination_host sudo bash -c "'${wp_cli_prod} --path=\"${destination_dir}\" action-scheduler run'"`
    sanity_check $? "Error with running action scheduler on Wordpress on production : $check_wordpress_action_scheduler"

fi

# Standard (non-WooCommerce) database push
if [ "$woocommerce_enable" == "false" ]
then
    echo "Dumping staging database to temp file.."
    check_staging_temp=`ssh -l $staging_user $staging_host sudo bash -c "'/usr/bin/mysqldump -u $staging_db_user --password=\"$staging_db_password\" -h $staging_db_host $staging_db_name'" > ${scriptpath}/sqltmp/sqltmp.sql`
    sanity_check $? "Error with dumping staging database to temp file : $check_staging_temp"

    # Restart galera prior to database copy to avoid flow control issues
    if [ "$galera_restart" == "true" ]
    then
        check_galera_restart=`ssh -l $destination_user $destination_host sudo bash -c "'systemctl restart mysqld'"`
        sanity_check $? "Error with restarting galera database service on production : $check_galera_restart"
    fi

    echo "Transferring staging database to production.."
    check_prod_db=`cat ${scriptpath}/sqltmp/sqltmp.sql | ssh -l $destination_user $destination_host sudo bash -c "'/usr/bin/mysql -u $prod_db_user --password=\"$prod_db_password\" -h $prod_db_host $prod_db_name'"`
    sanity_check $? "Error with production database transfer : $check_prod_db"

fi

# URL search-replace staging -> production
echo "Fixing URLs on production.."
destination_siteurl=$(ssh -l $destination_user $destination_host "cd $destination_dir;sudo ${wp_cli_prod} option get siteurl") 
destination_siteurl_encoded=$(urlencode "${destination_siteurl}")
staging_siteurl=$(ssh -l $staging_user $staging_host "cd $source_dir;sudo ${wp_cli_staging} option get siteurl")
staging_siteurl_encode=$(urlencode "${staging_siteurl}")

echo "Staging site url : ${staging_siteurl}"
echo "Staging site url encode : ${staging_siteurl_encode}"
echo "Destination site url encode : ${destination_siteurl_encoded}"
echo "Destination site url : ${destination_siteurl}"

echo "${wp_cli_prod} search-replace $staging_siteurl_encode $destination_siteurl_encode --all-tables --precise;"

ssh -l $destination_user $destination_host \
    "cd $destination_dir;\
    sudo ${wp_cli_prod} search-replace \"$staging_siteurl\" \"$destination_siteurl\" --all-tables --precise;\
    sudo ${wp_cli_prod} search-replace \"$staging_siteurl_encode\" \"$destination_siteurl_encode\" --all-tables --precise;\
    sudo ${wp_cli_prod} cache flush"

# Cache clearing
if [ "$wprocket" == "true" ]
then
    echo "Clearing WP Rocket .."
	ssh -l $destination_user $destination_host \
    	"cd $destination_dir;\
		sudo ${wp_cli_prod} rocket clean --confirm;\
	    sudo ${wp_cli_prod} rocket preload --sitemap;\
	    sudo ${wp_cli_prod} rocket regenerate --file=config --nginx=true;\
        sudo rm -rf $destination_dir/wp-content/cache/*"
fi

if [ "$flyingpress" == "true" ]
then
    echo "Clearing Flying press .."
    ssh -l $destination_user $destination_host \
        "cd $destination_dir;\
        sudo ${wp_cli_prod} purge-everything;\
        sudo ${wp_cli_prod} preload-cache"
fi

# Maintenance mode off
echo "Disabling maintenance mode.."
ssh -l $destination_user $destination_host \
    "cd $destination_dir;\
    sudo mv maintenance_on.html maintenance_off.html"

echo "Push script complete for $site_name" | mail -s "Push script complete : $site_name" $notification_email

