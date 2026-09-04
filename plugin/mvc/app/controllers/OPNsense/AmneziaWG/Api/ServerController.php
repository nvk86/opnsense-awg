<?php
namespace OPNsense\AmneziaWG\Api;
use OPNsense\Base\ApiMutableModelControllerBase;
use OPNsense\Core\Backend;

class ServerController extends ApiMutableModelControllerBase
{
    protected static $internalModelClass='\\OPNsense\\AmneziaWG\\Server';
    protected static $internalModelName='server';
    const PRIVKEY_DIR='/usr/local/etc/amnezia';
    const PRIVKEY_SENTINEL='::file::';
    const HANDSHAKE_FRESH_SEC=180;

    public function searchItemAction()
    {
        $r=$this->searchBase('server',['enabled','name','description','interface_number','listen_port','address']);
        $status=json_decode((string)(new Backend())->configdRun('amneziawg status'),true);
        $live=null;
        if(is_array($status)) { $live=[]; foreach(($status['tunnels']??[]) as $t){$live[(string)($t['interface']??'')]=(int)($t['latest_handshake']??0);} }
        foreach($r['rows'] as &$row){
            if($live===null){$row['runtime']='';continue;}
            $iface='awg'.(int)($row['interface_number']??0);
            if(!array_key_exists($iface,$live))$row['runtime']='stopped';
            elseif($live[$iface]>0 && time()-$live[$iface]<=self::HANDSHAKE_FRESH_SEC)$row['runtime']='running';
            else $row['runtime']='listening';
        }
        unset($row); return $r;
    }

    public function getItemAction($uuid=null)
    {
        $r=$this->getBase('server','server',$uuid);
        if(isset($r['server'])){
            $stored=(string)($r['server']['private_key']??'');
            $disk=$uuid!==null && file_exists($this->keyFilePath((string)$uuid));
            $hasUsableKey=$disk || ($stored!=='' && $stored!==self::PRIVKEY_SENTINEL);
            $r['server']['private_key']=$hasUsableKey?str_repeat("\xE2\x80\xA2",44):'';
            foreach(['i1','i2','i3','i4','i5'] as $f){if(!empty($r['server'][$f])){$v=html_entity_decode((string)$r['server'][$f],ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8');$r['server'][$f]=html_entity_decode($v,ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8');}}
            if($uuid===null)$r['server']['interface_number']=(string)$this->nextFreeInterfaceNumber();
        } return $r;
    }

    public function addItemAction()
    {
        if(!$this->request->isPost())return ['result'=>'failed'];
        $body=$this->request->getPost('server',null,[]);
        $prep=$this->prepareSubmittedKey($body,null); if(isset($prep['validations']))return ['result'=>'failed','validations'=>$prep['validations']];
        $v=array_merge($this->validateHFields($body),$this->validateAwg31Ranges($body),$this->validateKeepaliveRange($body['clients_keepalive']??''),$this->validateInterfaceNumber($body,null),$this->validateListenPort($body,null),$this->validateClientsEndpoint($body),$this->validateName($body,null));
        if($v)return ['result'=>'failed','validations'=>$v];
        $_POST['server']['private_key']=self::PRIVKEY_SENTINEL;
        $r=$this->addBase('server','server');
        if (($r['result'] ?? '') !== 'failed' && $prep['key'] !== null && !empty($r['uuid'])) {
            try { $this->writePrivateKey((string)$r['uuid'], $prep['key']); }
            catch (\RuntimeException $e) {
                $this->delBase('server',(string)$r['uuid']);
                return ['result'=>'failed','validations'=>['server.private_key'=>$e->getMessage()]];
            }
        }
        return $r;
    }

    public function setItemAction($uuid)
    {
        if(!$this->request->isPost())return ['result'=>'failed'];
        $body=$this->request->getPost('server',null,[]);
        $prep=$this->prepareSubmittedKey($body,(string)$uuid); if(isset($prep['validations']))return ['result'=>'failed','validations'=>$prep['validations']];
        $v=array_merge($this->validateHFields($body),$this->validateAwg31Ranges($body),$this->validateKeepaliveRange($body['clients_keepalive']??''),$this->validateInterfaceNumber($body,(string)$uuid),$this->validateListenPort($body,(string)$uuid),$this->validateClientsEndpoint($body),$this->validateName($body,(string)$uuid));
        if($v)return ['result'=>'failed','validations'=>$v];
        // Save/validate the model before replacing the private key. A failed
        // edit must never rotate the live key behind the user's back.
        $stagedKey=null;
        if($prep['key']!==null){
            try{$stagedKey=$this->stagePrivateKey($prep['key']);}
            catch(\RuntimeException $e){return ['result'=>'failed','validations'=>['server.private_key'=>$e->getMessage()]];}
        }
        $_POST['server']['private_key']=self::PRIVKEY_SENTINEL;
        $r=$this->setBase('server','server',$uuid);
        if (($r['result'] ?? '') === 'saved' && $stagedKey !== null) {
            try{$this->commitStagedPrivateKey($stagedKey,(string)$uuid);$stagedKey=null;}
            catch(\RuntimeException $e){@unlink($stagedKey);return ['result'=>'failed','validations'=>['server.private_key'=>$e->getMessage()]];}
        } elseif($stagedKey!==null) {
            @unlink($stagedKey);
        }
        return $r;
    }

    public function delItemAction($uuid)
    {
        // Refuse deleting a server while peers still reference it.
        $pm=new \OPNsense\AmneziaWG\Peer();
        foreach($pm->peer->iterateItems() as $p){if((string)$p->server===(string)$uuid)return ['result'=>'failed','validations'=>['server.name'=>'Remove or move server peers first']];}
        $r=$this->delBase('server',$uuid); if(($r['result']??'')==='deleted')@unlink($this->keyFilePath((string)$uuid)); return $r;
    }
    public function toggleItemAction($uuid,$enabled=null){return $this->toggleBase('server',$uuid,$enabled);}
    public function genKeyPairAction(){ $d=json_decode((string)(new Backend())->configdRun('amneziawg gen_keypair'),true); if(!isset($d['private_key'],$d['public_key']))return ['status'=>'error','message'=>$d['message']??'Key generation failed']; return ['status'=>'ok','private_key'=>$d['private_key'],'public_key'=>$d['public_key']]; }

    public function publicKeyAction($uuid='')
    {
        if(!preg_match('/^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$/',(string)$uuid))
            return ['status'=>'error','message'=>'Invalid server UUID'];
        $node=$this->getModel()->getNodeByReference('server.'.(string)$uuid);
        if($node===null)return ['status'=>'error','message'=>'Server not found'];
        $stored=(string)$node->private_key;
        if($stored===self::PRIVKEY_SENTINEL){
            $path=$this->keyFilePath((string)$uuid);
            if(!file_exists($path))return ['status'=>'error','message'=>'Server private key file is missing'];
            $private=trim((string)file_get_contents($path));
        } else {
            $private=trim($stored);
        }
        if(!preg_match('/^[A-Za-z0-9+\/]{43}=$/',$private))
            return ['status'=>'error','message'=>'Server private key is invalid or missing'];

        $proc=proc_open(['/usr/local/bin/awg','pubkey'],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);
        if(!is_resource($proc))return ['status'=>'error','message'=>'Unable to run awg pubkey'];
        fwrite($pipes[0],$private."\n"); fclose($pipes[0]);
        $public=trim((string)stream_get_contents($pipes[1])); fclose($pipes[1]);
        $err=trim((string)stream_get_contents($pipes[2])); fclose($pipes[2]);
        $rc=proc_close($proc);
        if($rc!==0 || !preg_match('/^[A-Za-z0-9+\/]{43}=$/',$public))
            return ['status'=>'error','message'=>$err!==''?$err:'Unable to derive server public key'];
        return ['status'=>'ok','public_key'=>$public];
    }

    private function prepareSubmittedKey(array $b,?string $uuid):array{
        $s=trim($b['private_key']??''); if(strpos($s,"\xE2\x80\xA2")!==false)return ['key'=>null];
        if($s===''){if($uuid===null||!file_exists($this->keyFilePath($uuid)))return ['validations'=>['server.private_key'=>'A private key is required']]; return ['key'=>null];}
        if(!preg_match('/^[A-Za-z0-9+\/]{43}=$/',$s))return ['validations'=>['server.private_key'=>'Private key must be a valid WireGuard Base64 key']]; return ['key'=>$s];
    }
    private function validateHFields(array $b):array{
        $ranges=[];$e=[]; foreach(['h1','h2','h3','h4'] as $f){$v=trim($b[$f]??'');if($v==='')continue;if(!preg_match('/^\d{1,10}(-\d{1,10})?$/',$v)){$e['server.'.$f]=strtoupper($f).' has invalid format';continue;} $p=explode('-',$v,2);$lo=(float)$p[0];$hi=isset($p[1])?(float)$p[1]:$lo;if($lo<1||$hi<1||$lo>4294967295||$hi>4294967295||$hi<$lo){$e['server.'.$f]=strtoupper($f).' must be 1-4294967295 and range start <= end';continue;}foreach($ranges as $pf=>[$pl,$ph])if($lo<=$ph&&$pl<=$hi){$e['server.'.$f]=strtoupper($f).' overlaps '.strtoupper($pf);break;}if(!isset($e['server.'.$f]))$ranges[$f]=[$lo,$hi];} return $e;
    }
    private function validateAwg31Ranges(array $b):array{
        $e=[]; foreach(['content_padding_addition','rekey_after_time','rekey_timeout','reject_after_time','keepalive_timeout','max_handshake_attempts'] as $f){$v=trim((string)($b[$f]??''));if($v==='')continue;$err=$this->validateUnsignedRangeValue($v,4294967295);if($err!=='')$e['server.'.$f]=$err;} return $e;
    }
    private function validateKeepaliveRange($v):array{$v=trim((string)$v);if($v==='')return [];$err=$this->validateUnsignedRangeValue($v,65535);return $err===''?[]:['server.clients_keepalive'=>$err];}
    private function validateUnsignedRangeValue(string $v,int $max):string{if(!preg_match('/^\d{1,10}(-\d{1,10})?$/',$v))return 'Must be a non-negative number or range';$p=explode('-',$v,2);$lo=(float)$p[0];$hi=isset($p[1])?(float)$p[1]:$lo;if($lo>$max||$hi>$max)return 'Value exceeds '.$max;if($hi<$lo)return 'Range start must not exceed range end';return '';}
    private function validateInterfaceNumber(array $b,?string $self):array{
        $n=trim($b['interface_number']??''); if($n==='')return [];
        foreach((new \OPNsense\AmneziaWG\Instance())->instance->iterateItems() as $x)if((string)$x->interface_number===$n)return ['server.interface_number'=>'Interface awg'.$n.' is already used by client tunnel "'.(string)$x->name.'"'];
        foreach($this->getModel()->server->iterateItems() as $u=>$x){if($self!==null&&(string)$u===$self)continue;if((string)$x->interface_number===$n)return ['server.interface_number'=>'Interface awg'.$n.' is already used by server "'.(string)$x->name.'"'];} return [];
    }
    private function validateListenPort(array $b,?string $self):array{
        $port=trim($b['listen_port']??''); if($port==='')return [];
        foreach((new \OPNsense\AmneziaWG\Instance())->instance->iterateItems() as $x)
            if(trim((string)$x->listen_port)===$port)return ['server.listen_port'=>'Listen port '.$port.' is already used by client tunnel "'.(string)$x->name.'"'];
        foreach($this->getModel()->server->iterateItems() as $u=>$x){
            if($self!==null&&(string)$u===$self)continue;
            if(trim((string)$x->listen_port)===$port)return ['server.listen_port'=>'Listen port '.$port.' is already used by server "'.(string)$x->name.'"'];
        }
        return [];
    }
    private function validateClientsEndpoint(array $b):array{
        $v=trim((string)($b['clients_endpoint']??''));if($v==='')return [];
        if(!preg_match('/^(?:[^\s:]+|\[[0-9a-fA-F:]+\]):(\d{1,5})$/',$v,$m) || (int)$m[1]<1 || (int)$m[1]>65535)return ['server.clients_endpoint'=>'Use host:port, IPv4:port, or [IPv6]:port with port 1-65535'];
        return [];
    }
    private function validateName(array $b,?string $self):array{$name=trim($b['name']??'');foreach($this->getModel()->server->iterateItems() as $u=>$x){if($self!==null&&(string)$u===$self)continue;if((string)$x->name===$name)return ['server.name'=>'Server name must be unique'];}return [];}
    private function nextFreeInterfaceNumber(): int
    {
        $used = [];
        foreach ((new \OPNsense\AmneziaWG\Instance())->instance->iterateItems() as $x) {
            $value = trim((string)$x->interface_number);
            if ($value !== '') {
                $used[(int)$value] = true;
            }
        }
        // getBase() creates a temporary blank item for the Add dialog; do not
        // accidentally count its empty interface_number as awg0.
        foreach ($this->getModel()->server->iterateItems() as $x) {
            $value = trim((string)$x->interface_number);
            if ($value !== '') {
                $used[(int)$value] = true;
            }
        }
        for ($i = 0; $i <= 99; $i++) {
            if (!isset($used[$i])) {
                return $i;
            }
        }
        return 99;
    }
    private function keyFilePath(string $u):string{return self::PRIVKEY_DIR.'/server-'.preg_replace('/[^a-fA-F0-9\-]/','',$u).'.key';}
    private function stagePrivateKey(string $k):string{
        if(!is_dir(self::PRIVKEY_DIR)&&!mkdir(self::PRIVKEY_DIR,0700,true))throw new \RuntimeException('Cannot create key directory');
        @chmod(self::PRIVKEY_DIR,0700);
        $tmp=tempnam(self::PRIVKEY_DIR,'.server-keytmp-');
        if($tmp===false)throw new \RuntimeException('Cannot create temporary server key file');
        if(file_put_contents($tmp,trim($k)."\n",LOCK_EX)===false){@unlink($tmp);throw new \RuntimeException('Cannot write server private key');}
        if(!chmod($tmp,0600)){@unlink($tmp);throw new \RuntimeException('Cannot secure server private key permissions');}
        return $tmp;
    }
    private function commitStagedPrivateKey(string $tmp,string $u):void{
        if(!rename($tmp,$this->keyFilePath($u)))throw new \RuntimeException('Cannot install server private key');
    }
    private function writePrivateKey(string $u,string $k):void{
        $tmp=$this->stagePrivateKey($k);
        try{$this->commitStagedPrivateKey($tmp,$u);$tmp='';}
        finally{if($tmp!==''&&file_exists($tmp))@unlink($tmp);}
    }
}
