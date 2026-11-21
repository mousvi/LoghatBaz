/* LoghatBaz curriculum loader
 * Vocabulary source: Openjam (MIT), English-Persian, 35 topic categories.
 * API: https://openjam.amirj4m.com
 * Exactly 400 stages x 15 unique English lemmas = 6,000 words.
 */
(function(){
  const API='https://openjam.amirj4m.com/v1';
  const CACHE_KEY='loghatbaz_curriculum_6000_v1';
  const EMOJI={
    food:'🍎',drink:'🥤',body:'🫀',clothing:'👕',home:'🏠',animal:'🐾',
    plant:'🌿',nature:'🌦️',vehicle:'🚗',tool:'🛠️',family:'👨‍👩‍👧‍👦',
    person:'🧑',profession:'💼',relationship:'🤝',emotion:'😊',society:'🏙️',
    place:'📍',country:'🌍',city:'🌆',travel:'🧳',work:'💼',school:'🎓',
    sport:'⚽',arts:'🎨',religion:'🕌',media:'📺',health:'🩺',science:'🔬',
    technology:'💻',time:'⏰',money:'💰',quality:'✨',action:'🏃',
    abstract:'💡',event:'🎉'
  };
  function valid(data){
    if(!data||!Array.isArray(data.words)||!Array.isArray(data.levels))return false;
    if(data.words.length!==6000||data.levels.length!==400)return false;
    const seen=new Set();
    for(const w of data.words){
      if(!Array.isArray(w)||!w[0]||!w[1])return false;
      const key=String(w[0]).toLowerCase();
      if(seen.has(key))return false;
      seen.add(key);
    }
    const used=[];
    for(const s of data.levels){
      if(!Array.isArray(s.ids)||s.ids.length!==15||!s.ids.every(i=>Number.isInteger(i)&&i>=0&&i<6000))return false;
      used.push(...s.ids);
    }
    return used.length===6000&&new Set(used).size===6000;
  }
  async function json(path){
    const response=await fetch(API+path,{headers:{Accept:'application/json'}});
    if(!response.ok)throw new Error('واژگان آنلاین پاسخ ندادند ('+response.status+').');
    return response.json();
  }
  async function inBatches(items,size,fn){
    for(let i=0;i<items.length;i+=size){
      await Promise.all(items.slice(i,i+size).map(fn));
    }
  }
  function makePools(categories,raw){
    const seen=new Set();
    return categories.map(cat=>{
      const pool=[];
      for(const item of (raw[cat.slug]||[])){
        const english=String(item.english||'').trim().toLowerCase();
        if(!/^[a-z]+(?:[-'][a-z]+)*$/.test(english)||english.length>28||seen.has(english))continue;
        const translations=Array.isArray(item.translations)?item.translations:[];
        const tr=translations.find(x=>x&&typeof x.meaning==='string'&&x.meaning.trim());
        if(!tr)continue;
        const meaning=tr.meaning.trim().replace(/\s+/g,' ').replace(/[&<>]/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[ch]));
        if(meaning.length>90)continue;
        seen.add(english);
        pool.push([english,meaning,'',EMOJI[cat.slug]||'📘']);
      }
      return {category:cat,words:pool};
    });
  }
  function buildStages(pools){
    const levels=[],words=[];
    const cursor=pools.map(()=>0),part=pools.map(()=>0);
    while(levels.length<400){
      let advanced=false;
      for(let i=0;i<pools.length&&levels.length<400;i++){
        const pool=pools[i].words,at=cursor[i];
        if(pool.length-at<15)continue;
        const ids=[];
        for(let j=0;j<15;j++){
          ids.push(words.length);
          words.push(pool[at+j]);
        }
        cursor[i]+=15;part[i]++;
        const cat=pools[i].category;
        levels.push({
          title:(cat.name_fa||cat.name_en||cat.slug)+' · بخش '+part[i],
          emoji:EMOJI[cat.slug]||'📘',
          category:cat.slug,
          ids
        });
        advanced=true;
      }
      if(!advanced)break;
    }
    return {words,levels,capacity:levels.length};
  }
  window.loadLoghatCurriculum=async function(force){
    if(!force){
      try{
        const cached=JSON.parse(localStorage.getItem(CACHE_KEY)||'null');
        if(valid(cached)&&Date.now()-cached.savedAt<7*24*60*60*1000)return cached;
      }catch(e){}
    }
    const response=await json('/categories/groups');
    const groups=Array.isArray(response.groups)?response.groups:[];
    const categories=groups.flatMap(group=>(group.children||[]).map(cat=>({
      ...cat,group_name_fa:group.name_fa
    })));
    if(!categories.length)throw new Error('فهرست موضوعات دریافت نشد.');
    const raw={};
    const offsets={};
    await inBatches(categories,6,async cat=>{
      const data=await json('/categories/'+encodeURIComponent(cat.slug)+'/words?lang=fa&limit=500&offset=0');
      raw[cat.slug]=Array.isArray(data.data)?data.data:[];
      offsets[cat.slug]=500;
    });
    let pools=makePools(categories,raw);
    let built=buildStages(pools);
    // If category overlap leaves fewer than 400 complete decks, pull further
    // pages from the largest categories. Keep total API calls below the 60/min limit.
    const extras=categories.filter(cat=>(cat.word_count||0)>500)
      .sort((a,b)=>(b.word_count||0)-(a.word_count||0));
    let extraCalls=0;
    for(const cat of extras){
      if(built.capacity>=400||extraCalls>=20)break;
      const offset=offsets[cat.slug]||500;
      if(offset>=(cat.word_count||0))continue;
      const data=await json('/categories/'+encodeURIComponent(cat.slug)+'/words?lang=fa&limit=500&offset='+offset);
      raw[cat.slug]=(raw[cat.slug]||[]).concat(Array.isArray(data.data)?data.data:[]);
      offsets[cat.slug]=offset+500;
      extraCalls++;
      pools=makePools(categories,raw);
      built=buildStages(pools);
    }
    if(built.capacity<400){
      throw new Error('واژه‌های یکتای دارای ترجمهٔ فارسی کافی نیست؛ فقط '+built.capacity+' مرحلهٔ کامل ساخته شد. انتشار متوقف شد تا لغت تکراری وارد نشود.');
    }
    if(built.words.length!==6000||built.levels.length!==400||new Set(built.words.map(w=>w[0])).size!==6000){
      throw new Error('اعتبارسنجی نهایی ۶۰۰۰ واژه و ۴۰۰ مرحله موفق نبود.');
    }
    const result={words:built.words,levels:built.levels,savedAt:Date.now()};
    try{localStorage.setItem(CACHE_KEY,JSON.stringify(result));}catch(e){}
    return result;
  };
})();