/* LoghatBaz curriculum loader (offline)
 * Reads the 6,000-word curriculum (400 stages x 15 unique English lemmas)
 * from words.json, which ships inside the app. No network is needed.
 * words.json is generated once by tools/fetch_words.py from the Openjam
 * vocabulary database (MIT, see THIRD_PARTY_NOTICES.md).
 */
(function(){
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
  window.loadLoghatCurriculum=async function(){
    let response;
    try{
      response=await fetch('words.json',{headers:{Accept:'application/json'}});
    }catch(e){
      throw new Error('فایل واژگان خوانده نشد؛ برنامه را دوباره باز کن.');
    }
    if(!response.ok)throw new Error('فایل واژگان پیدا نشد ('+response.status+').');
    const data=await response.json();
    if(!valid(data))throw new Error('ساختار بانک واژگان معتبر نیست.');
    return {words:data.words,levels:data.levels,savedAt:Date.now()};
  };
})();
