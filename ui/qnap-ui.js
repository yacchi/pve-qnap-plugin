// Storage editor for the QNAP plugin in the Proxmox VE web UI.
//
// The web UI only opens Add/Edit dialogs for storage types listed in
// PVE.Utils.storageSchema, so a custom plugin cannot be edited there. This
// file is appended to pvemanagerlib.js by /usr/share/pve-qnap-plugin/ui-patch
// and registers an editor for the 'qnap' type.
//
// It builds on PVE.panel.StorageBase, which is internal to the web UI rather
// than a stable API. Everything is wrapped in try/catch so that, should a
// Proxmox VE update break it, only this editor is lost and the rest of the UI
// keeps working. 'pvesm add/set' always works regardless.
// No 'use strict': ExtJS callParent() finds the overridden method through the
// caller chain, which strict mode hides.
(function () {
    try {
        if (typeof PVE === 'undefined' || !PVE.Utils || !PVE.Utils.storageSchema) {
            return;
        }

        const WINDOW_WIDTH = 800;
        const LABEL_WIDTH = 120;

        // Optional booleans: a value equal to the default is left out of the config.
        const flag = (name, label, defaultValue) => ({
            xtype: 'proxmoxcheckbox',
            name: name,
            fieldLabel: label,
            checked: !!defaultValue,
            uncheckedValue: 0,
            defaultValue: defaultValue ? '1' : 0,
            deleteDefaultValue: true,
        });

        Ext.define('PVE.storage.QnapInputPanel', {
            extend: 'PVE.panel.StorageBase',

            onlineHelp: 'chapter_storage',

            onGetValues: function (values) {
                let me = this;

                // Empty password on edit: keep the stored one.
                if (!values.password) {
                    delete values.password;
                }
                // 'delete' is only valid on update.
                if (me.isCreate) {
                    delete values.delete;
                }

                return me.callParent([values]);
            },

            setValues: function (values) {
                if (typeof values['qnap-iser-nodes'] === 'string') {
                    values['qnap-iser-nodes'] = values['qnap-iser-nodes'].split(',');
                }
                if (values['qnap-transport'] === undefined) {
                    values['qnap-transport'] = '__default__';
                }
                return this.callParent([values]);
            },

            updateIserNodes: function () {
                let me = this;
                let transport = me.down('field[name=qnap-transport]');
                let nodes = me.down('field[name=qnap-iser-nodes]');
                if (transport && nodes) {
                    nodes.setDisabled(transport.getValue() !== 'iser');
                }
            },

            initComponent: function () {
                let me = this;
                let isCreate = me.isCreate;

                me.column1 = [
                    {
                        xtype: isCreate ? 'textfield' : 'displayfield',
                        name: 'server',
                        fieldLabel: gettext('Server'),
                        emptyText: 'NAS address for the management API',
                        allowBlank: false,
                    },
                    {
                        xtype: 'proxmoxintegerfield',
                        name: 'qnap-api-port',
                        fieldLabel: 'API port',
                        minValue: 1,
                        maxValue: 65535,
                        emptyText: '443',
                        deleteEmpty: !isCreate,
                    },
                    {
                        xtype: 'proxmoxtextfield',
                        name: 'username',
                        fieldLabel: gettext('Username'),
                        emptyText: 'admin',
                        deleteEmpty: !isCreate,
                    },
                    {
                        xtype: 'textfield',
                        inputType: 'password',
                        name: 'password',
                        fieldLabel: gettext('Password'),
                        emptyText: isCreate ? '' : gettext('(unchanged)'),
                        allowBlank: !isCreate,
                    },
                    {
                        xtype: isCreate ? 'textfield' : 'displayfield',
                        name: 'portal',
                        fieldLabel: 'Portal',
                        emptyText: 'iSCSI portal (data network)',
                        allowBlank: false,
                    },
                    {
                        xtype: isCreate ? 'textfield' : 'displayfield',
                        name: 'target',
                        fieldLabel: 'Target',
                        emptyText: 'iqn.2004-04.com.qnap:...',
                        allowBlank: false,
                    },
                ];

                me.column2 = [
                    {
                        xtype: 'pveContentTypeSelector',
                        cts: ['images', 'rootdir'],
                        name: 'content',
                        value: ['images'],
                        multiSelect: true,
                        fieldLabel: gettext('Content'),
                        allowBlank: false,
                    },
                    {
                        xtype: isCreate ? 'proxmoxintegerfield' : 'displayfield',
                        name: 'qnap-pool-id',
                        fieldLabel: 'Pool ID',
                        minValue: 1,
                        allowBlank: false,
                    },
                    isCreate
                        ? {
                              xtype: 'proxmoxKVComboBox',
                              name: 'qnap-blocksize',
                              fieldLabel: 'Block size',
                              value: '__default__',
                              comboItems: [
                                  ['__default__', Proxmox.Utils.defaultText + ' (16k)'],
                                  ['4k', '4k'],
                                  ['8k', '8k'],
                                  ['16k', '16k'],
                                  ['32k', '32k'],
                                  ['64k', '64k'],
                                  ['128k', '128k'],
                              ],
                          }
                        : {
                              xtype: 'displayfield',
                              name: 'qnap-blocksize',
                              fieldLabel: 'Block size',
                              renderer: (v) => v || '16k',
                          },
                    {
                        xtype: 'proxmoxcheckbox',
                        name: 'shared',
                        fieldLabel: gettext('Shared'),
                        checked: true,
                        uncheckedValue: 0,
                    },
                    {
                        xtype: 'proxmoxKVComboBox',
                        name: 'qnap-transport',
                        fieldLabel: 'Transport',
                        value: '__default__',
                        deleteEmpty: !isCreate,
                        comboItems: [
                            ['__default__', Proxmox.Utils.defaultText + ' (TCP)'],
                            ['tcp', 'TCP'],
                            ['iser', 'iSER (RDMA)'],
                        ],
                        listeners: {
                            change: function () {
                                me.updateIserNodes();
                            },
                        },
                    },
                    {
                        xtype: 'pveNodeSelector',
                        name: 'qnap-iser-nodes',
                        fieldLabel: 'iSER nodes',
                        emptyText: gettext('All'),
                        multiSelect: true,
                        autoSelect: false,
                        skipEmptyText: true,
                        deleteEmpty: !isCreate,
                        disabled: true,
                    },
                ];

                me.columnB = [
                    {
                        xtype: 'displayfield',
                        userCls: 'pmx-hint',
                        value:
                            'iSER needs an RDMA NIC on the node, a switch set up for RoCE and ' +
                            'iSER enabled on the NAS. Other nodes, and nodes whose iSER login ' +
                            'fails, use TCP. A running session keeps its transport until it is ' +
                            'logged out.',
                    },
                ];

                me.advancedColumn1 = [
                    flag('qnap-compression', 'Compression (LZ4)', 1),
                    flag('qnap-ssd-cache', 'SSD cache', 1),
                    flag('qnap-dedup', 'Deduplication', 0),
                    flag('qnap-fast-clone', 'Fast clone', 0),
                ];

                me.advancedColumn2 = [
                    {
                        xtype: 'proxmoxKVComboBox',
                        name: 'qnap-sync',
                        fieldLabel: 'Sync',
                        value: '__default__',
                        deleteEmpty: !isCreate,
                        comboItems: [
                            ['__default__', Proxmox.Utils.defaultText + ' (standard)'],
                            ['standard', 'standard'],
                            ['always', 'always'],
                            ['disabled', 'disabled'],
                        ],
                    },
                    {
                        xtype: 'proxmoxintegerfield',
                        name: 'qnap-threshold',
                        fieldLabel: 'Warn at (%)',
                        minValue: 0,
                        maxValue: 100,
                        emptyText: '80',
                        deleteEmpty: !isCreate,
                    },
                    flag('qnap-verify-tls', 'Verify TLS', 0),
                ];

                me.callParent();
                me.updateIserNodes();

                // Proxmox.window.Edit sizes the dialog for 100px labels (600px
                // wide), which truncates the hints and wraps longer labels.
                // BaseEdit takes no size from the panel, so widen it here.
                me.query('[isFormField]').forEach((field) => {
                    field.labelWidth = LABEL_WIDTH;
                });
                me.on(
                    'afterrender',
                    () => {
                        let win = me.up('window');
                        if (win && win.getWidth() < WINDOW_WIDTH) {
                            win.setWidth(WINDOW_WIDTH);
                            win.center();
                        }
                    },
                    me,
                    { single: true },
                );
            },
        });

        PVE.Utils.storageSchema.qnap = {
            name: 'QNAP',
            ipanel: 'QnapInputPanel',
            faIcon: 'building',
            backups: false,
        };
    } catch (err) {
        if (typeof console !== 'undefined') {
            console.error('pve-qnap-plugin: web UI editor not loaded:', err);
        }
    }
})();
