<?php

namespace OPNsense\AmneziaWG;

class ClientsController extends PageControllerBase
{
    public function indexAction()
    {
        $this->prepareView('clients');
    }
}
