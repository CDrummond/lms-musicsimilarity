Vue.component('musicsimilarity', {
    template: `
<v-dialog v-model="show" v-if="show" persistent scrollable width="600">
 <v-card>
  <v-card-title>{{title}}</v-card-title>
  <v-card-text>
   <v-layout wrap :disabled="running" style="margin-top:-16px">
    <v-flex xs12 sm4 style="padding-top:19px; padding-right:8px">Name</v-flex>
    <v-flex xs12 sm8><v-text-field v-model="name" hide-details single-line></v-text-field></v-flex>
   </v-layout>
   <div style="margin-bottom:16px; margin-top:24px">
    <v-list-tile-title><b>Low-level attributes</b></v-list-tile-title>
    <v-list-tile-sub-title>Adjust values for attributes you wish to filter on. Using 0 will cause attribute to not be filtered on.</v-list-tile-sub-title>
   </div>
   <template v-for="(attr, index) in lowlevel">
    <v-layout wrap :disabled="running">
     <v-flex xs12 sm4 style="padding-top:19px; padding-right:8px">{{attr.label}}</v-flex>
     <v-flex xs12 sm3><v-text-field v-model="attr.min" hide-details single-line type="number"></v-text-field></v-flex>
     <v-flex xs12 sm1></v-flex>
     <v-flex xs12 sm3><v-text-field v-model="attr.max" hide-details single-line type="number"></v-text-field></v-flex>
     <v-flex xs12 sm1></v-flex>
    </v-layout>
   </template>
   <v-layout wrap :disabled="running">
    <v-flex xs12 sm4 style="margin-top:28px"><div>Genres</div></v-flex>
    <v-flex xs12 sm8 style="padding-top:8px">
     <v-select chips deletable-chips multiple :items="genres" :label="i18n('Selected Genres')" v-model="chosenGenres">
      <v-list-tile slot="prepend-item" @click="toggleGenres()">
       <v-list-tile-action><v-icon>{{selectAllIcon}}</v-icon></v-list-tile-action>
       <v-list-tile-title>{{i18n('Select All')}}</v-list-tile-title>
      </v-list-tile>
      <v-divider slot="prepend-item"></v-divider>
      <template v-slot:selection="{ item, index }">
        <v-chip v-if="(index < 5) || chosenGenres.length==6" close @input="chosenGenres.splice(index, 1)">
         <span>{{ item }}</span>
        </v-chip>
        <span v-if="index == 5 && chosenGenres.length>6" class="subtext">{{i18n("(+%1 others)", chosenGenres.length - 5) }}</span>
      </template>
     </v-select>
    </v-flex>
   </v-layout>
   <div style="margin-bottom:16px; margin-top:24px">
    <v-list-tile-title><b>High-level attributes</b></v-list-tile-title>
    <v-list-tile-sub-title>Adjust values for attributes you wish to filter on. Using 0, or 50, will cause attribute to not be filtered on. Values higher than 50 imply a high probability that a track matches the attribute. Likewise less than 50 implies not having that attribute.</v-list-tile-sub-title>
   </div>
   <template v-for="(attr, index) in highlevel">
    <v-layout wrap :disabled="running">
     <v-flex xs12 sm4 style="margin-top:18px"><div>{{attr.label}}</div></v-flex>
     <v-flex xs12 sm8 style="padding-top:18px"><v-slider min="0" max="100" thumb-label="always" v-model="attr.value"></v-slider></v-flex>
    </v-layout>
   </template>
  </v-card-text>
  <v-card-actions>
   <div v-if="running" style="padding-left:8px">Creating...</div>
   <v-spacer></v-spacer>
   <v-btn :disabled="running" flat @click.native="save()">{{saveButtonText}}</v-btn>
   <v-btn :disabled="running" flat @click.native="cancel()">Cancel</v-btn>
  </v-card-actions>
 </v-card>
</v-dialog>
`,
    props: [],
    data() {
        return {
            valid: false,
            show: false,
            running: false,
            title: undefined,
            name: undefined,
            lowlevel: [
                { key:'duration', label:'Duration (seconds)', min:0, max:600},
                { key:'bpm', label:'BPM', min:0, max:200 },
                { key:'loudness', label:'Loudness', min:0, max:100}
            ],
            highlevel: [
                { key:'danceable', label:'Danceable', value:50 },
                { key:'aggressive', label:'Aggressive', value:50 },
                { key:'electronic', label:'Electronic', value:50 },
                { key:'acoustic', label:'Acoustic', value:50 },
                { key:'happy', label:'Happy', value:50 },
                { key:'sad', label:'Sad', value:50 },
                { key:'party', label:'Party', value:50 },
                { key:'relaxed', label:'Relaxed', value:50 },
                { key:'dark', label:'Dark', value:50 },
                { key:'tonal', label:'Tonal', value:50 },
                { key:'voice', label:'Voice', value:50 } ],
            genres: [],
            chosenGenres: []
        }
    },
    mounted() {
        bus.$on('musicsimilarity.open', function(id) {
            this.running = false;
            lmsList("", ["genres"], undefined, 0, 1000).then(({data}) => {
                this.genres = [];
                if (data && data.result && data.result.genres_loop) {
                    for (var idx=0, loop=data.result.genres_loop, loopLen=loop.length; idx<loopLen; ++idx) {
                        this.genres.push(loop[idx].genre);
                    }
                }
                if (undefined==id) {
                    this.title='Add new Smart Mix';
                    this.name = undefined;
                    this.show = true;
                } else {
                    this.title='Edit Smart Mix';
                    this.name = id;
                    this.chosenGenres = [];
                    lmsCommand("", ["musicsimilarity", "readmix", "mix:"+id]).then(({data}) => {
                        if (data && data.result && data.result.body) {
                            this.setFields(JSON.parse(data.result.body));
                        }
                        this.show = true;
                    });
                }
            });
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
        },
        save() {
            var json = this.build();
            if (undefined==json) {
                return;
            }
            var name = undefined==this.id ? undefined : this.id.trim();
            var createMix = undefined==name || name.length<1;
            var command = createMix ? ['musicsimilarity', 'mix', 'body:'+json, 'menu:1', 'attrmix:1']
                                    : ['musicsimilarity', 'mix', 'mix:'+name, 'body:'+json, 'menu:1', 'attrmix:1'];

            this.running = true;
            lmsCommand("", command).then(({data}) => {
                var resp = parseBrowseResp(data, {id:'smartmix'}, {isSearch:true});
                bus.$emit('pluginListResponse', {title: createMix ? 'Smart Mix' :( 'Smart Mix: ' + name), id:'smartmix'}, {command:command, params:[]}, resp);
                this.show = false;
            }).catch(err => {
                this.running = false;
                logError(err);
            });
        },
        build() {
            var valid = false;
            var data = {format:'text'};
            for (var i=0, loop=this.lowlevel, len=loop.length; i<len; ++i) {
                if (loop[i].min>0) {
                    data['min'+loop[i].key]=loop[i].min;
                    valid = true;
                }
                if (loop[i].max>0) {
                    data['max'+loop[i].key]=loop[i].max;
                    valid = true;
                }
            }
            for (var i=0, loop=this.highlevel, len=loop.length; i<len; ++i) {
                if (loop[i].value>0 && loop[i].value!=50) {
                    data[loop[i].key]=loop[i].value;
                    valid = true;
                }
            }
            if (this.chosenGenres.length>0) {
                data['genre']=this.chosenGenres;
                valid = true;
            }
            return valid ? JSON.stringify(data) : undefined;
        },
        setFields(data) {
            for (var i=0, loop=this.lowlevel, len=loop.length; i<len; ++i) {
                loop[i].min = undefined!=data['min'+loop[i].key] ? parseInt(data['min'+loop[i].key]) : 0;
                loop[i].max = undefined!=data['max'+loop[i].key] ? parseInt(data['max'+loop[i].key]) : 0;
            }
            for (var i=0, loop=this.highlevel, len=loop.length; i<len; ++i) {
                loop[i].value = undefined!=data[loop[i].key] ? parseInt(data[loop[i].key]) : 50;
            }
            if (undefined!=data.genre) {
                for (var i=0, len=data.genre.length; i<len; ++i) {
                    if (this.genres.includes(data.genre[i])) {
                        this.chosenGenres.push(data.genre[i]);
                    }
                }
            }
        },
        toggleGenres() {
            if (this.chosenGenres.length==this.genres.length) {
                this.chosenGenres = [];
            } else {
                this.chosenGenres = this.genres.slice();
            }
        },
        i18n(str, val) {
            if (this.show) {
                return i18n(str, val);
            } else {
                return str;
            }
        }
    },
    computed: {
        saveButtonText() {
            return undefined==this.id || this.id.trim().length<1 ? 'Create Mix' : 'Save';
        },
        selectAllIcon () {
            if (this.chosenGenres.length==this.genres.length) {
                return "check_box";
            }
            if (this.chosenGenres.length>0) {
                return "indeterminate_check_box";
            }
            return "check_box_outline_blank";
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

