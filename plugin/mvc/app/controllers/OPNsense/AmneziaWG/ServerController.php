<?php

namespace OPNsense\AmneziaWG;

class ServerController extends PageControllerBase
{
    public function indexAction()
    {
        $this->prepareView('server');
    }
}
