Vue.component('musicsimilarity', {
    template: `
<v-dialog v-model="show" v-if="show" persistent width="600">
 <v-card>
  <v-card-title>XXXXX</v-card-title>
  <v-form ref="form" v-model="valid" lazy-validation>
   <v-list two-line>
   </v-list>
  </v-form>
  <v-card-actions>
   <v-spacer></v-spacer>
   <v-btn flat @click.native="cancel()">Cancel</v-btn>
  </v-card-actions>
 </v-card>
</v-dialog>
`,
    props: [],
    data() {
        return {
            valid: false,
            show: false
        }
    },
    mounted() {
        bus.$on('musicsimilarity.open', function(id) {
        console.log('open msim', id);
            this.show = true;
        }.bind(this));
        bus.$on('esc', function() {
            if (this.$store.state.activeDialog == 'musicsimilarity') {
                this.show=false;
            }
        }.bind(this));
    },
    methods: {
        cancel() {
            this.show=false;
        }
    },
    watch: {
        'show': function(val) {
            this.$store.commit('dialogOpen', {name:'musicsimilarity', shown:val});
        }
    }
})

bus.$on('musicsimilarity-remove', function(id, name) {
    confirm(i18n("Delete '%1'?", name), i18n('Delete')).then(res => {
        if (res) {
            lmsCommand("", ["musicsimilarity", "delmix", "mix:"+id]).then(({data}) => {
                logJsonMessage("RESP", data);
                bus.$emit('refreshList');
            }).catch(err => {
            });
        }
    });
});

