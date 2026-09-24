<?php
/**
 * Build-time only (image/Dockerfile): adds the scopes and themes of a fresh install to
 * app/etc/config.php so static content can be deployed without a database.
 * The original config.php is restored after the deploy.
 */
$file = $argv[1];
$config = include $file;
$config['scopes'] = [
    'websites' => [
        'admin' => ['website_id' => '0', 'code' => 'admin', 'name' => 'Admin', 'sort_order' => '0', 'default_group_id' => '0', 'is_default' => '0'],
        'base' => ['website_id' => '1', 'code' => 'base', 'name' => 'Main Website', 'sort_order' => '0', 'default_group_id' => '1', 'is_default' => '1'],
    ],
    'groups' => [
        0 => ['group_id' => '0', 'website_id' => '0', 'name' => 'Default', 'root_category_id' => '0', 'default_store_id' => '0', 'code' => 'default'],
        1 => ['group_id' => '1', 'website_id' => '1', 'name' => 'Main Website Store', 'root_category_id' => '2', 'default_store_id' => '1', 'code' => 'main_website_store'],
    ],
    'stores' => [
        'admin' => ['store_id' => '0', 'code' => 'admin', 'website_id' => '0', 'group_id' => '0', 'name' => 'Admin', 'sort_order' => '0', 'is_active' => '1'],
        'default' => ['store_id' => '1', 'code' => 'default', 'website_id' => '1', 'group_id' => '1', 'name' => 'Default Store View', 'sort_order' => '0', 'is_active' => '1'],
    ],
];
$config['themes'] = [
    'frontend/Magento/blank' => ['parent_id' => null, 'theme_path' => 'Magento/blank', 'theme_title' => 'Magento Blank', 'is_featured' => '0', 'area' => 'frontend', 'type' => '0', 'code' => 'Magento/blank'],
    'adminhtml/Magento/backend' => ['parent_id' => null, 'theme_path' => 'Magento/backend', 'theme_title' => 'Magento 2 backend', 'is_featured' => '0', 'area' => 'adminhtml', 'type' => '0', 'code' => 'Magento/backend'],
    'adminhtml/MageOS/m137-admin-theme' => ['parent_id' => 'Magento/backend', 'theme_path' => 'MageOS/m137-admin-theme', 'theme_title' => 'M137 Admin Theme', 'is_featured' => '0', 'area' => 'adminhtml', 'type' => '0', 'code' => 'MageOS/m137-admin-theme'],
    'frontend/Magento/luma' => ['parent_id' => 'Magento/blank', 'theme_path' => 'Magento/luma', 'theme_title' => 'Magento Luma', 'is_featured' => '0', 'area' => 'frontend', 'type' => '0', 'code' => 'Magento/luma'],
];
file_put_contents($file, "<?php\nreturn " . var_export($config, true) . ";\n");
